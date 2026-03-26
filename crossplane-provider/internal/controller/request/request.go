/*
Copyright 2022 The Crossplane Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package request

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	s4t "github.com/MIKE9708/s4t-sdk-go/pkg/api"
	read_config "github.com/MIKE9708/s4t-sdk-go/pkg/read_conf"

	xpv1 "github.com/crossplane/crossplane-runtime/apis/common/v1"
	"github.com/crossplane/crossplane-runtime/pkg/connection"
	"github.com/crossplane/crossplane-runtime/pkg/controller"
	"github.com/crossplane/crossplane-runtime/pkg/event"
	"github.com/crossplane/crossplane-runtime/pkg/ratelimiter"
	"github.com/crossplane/crossplane-runtime/pkg/reconciler/managed"
	"github.com/crossplane/crossplane-runtime/pkg/resource"
	"github.com/pkg/errors"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
	"k8s.io/apimachinery/pkg/types"

	"github.com/crossplane/provider-s4t/apis/iot/v1alpha1"
	apisv1alpha1 "github.com/crossplane/provider-s4t/apis/v1alpha1"
	"github.com/crossplane/provider-s4t/internal/features"
)

const (
	errNotRequest     = "managed resource is not a Request custom resource"
	errTrackPCUsage = "cannot track ProviderConfig usage"
	errGetPC        = "cannot get ProviderConfig"
	errGetCreds     = "cannot get credentials"
	errNewClient    = "cannot create new Service"
)

type S4TService struct {
	S4tClient *s4t.Client
	BaseURL   string
	Token     string
}

var (
	newS4TService = func(creds []byte, keystoneEndpoint string) (*S4TService, error) {
		var result map[string]string
		err := json.Unmarshal(creds, &result)
		if err != nil {
			return nil, errors.Wrap(err, errNewClient)
		}
		auth_req := read_config.FormatAuthRequ(
			result["username"],
			result["password"],
			result["domain"],
		)
		
		// Set Keystone endpoint via environment variable (OS_AUTH_URL)
		if keystoneEndpoint != "" {
			os.Setenv("OS_AUTH_URL", keystoneEndpoint)
		} else {
			os.Setenv("OS_AUTH_URL", "http://keystone.default.svc.cluster.local:5000/v3")
		}
		// Extract host from keystoneEndpoint BEFORE creating client
		// SDK uses hardcoded 127.0.0.1, we need to use Kubernetes service
		endpoint := keystoneEndpoint
		if endpoint == "" {
			endpoint = "http://keystone.default.svc.cluster.local:5000/v3"
		}
		if strings.HasSuffix(endpoint, "/v3") {
			endpoint = strings.TrimSuffix(endpoint, "/v3")
		}
		scheme := "http://"
		if strings.HasPrefix(endpoint, "https://") {
			scheme = "https://"
			endpoint = strings.TrimPrefix(endpoint, "https://")
		} else if strings.HasPrefix(endpoint, "http://") {
			endpoint = strings.TrimPrefix(endpoint, "http://")
		}
		if idx := strings.Index(endpoint, ":"); idx != -1 {
			endpoint = endpoint[:idx]
		}
		keystoneHost := scheme + endpoint
		
		// Create client manually with correct host (without port) instead of using GetClientConnection
		// SDK will derive final URL using AuthPort
		s4t_client := s4t.NewClient(keystoneHost)
		s4t_client.Port = "8812"
		s4t_client.AuthPort = "5000"
		
		// Authenticate with correct endpoint
		token, err := s4t_client.Authenticate(s4t_client, auth_req)
		if err != nil {
			return nil, errors.Wrap(err, errNewClient)
		}
		s4t_client.AuthToken = token
		
		iotronicHost := scheme + "iotronic-conductor.default.svc.cluster.local"
		s4t_client.Endpoint = iotronicHost
		
		if err != nil {
			return nil, errors.Wrap(err, errNewClient)
		}
		// Extract base URL and token from client if available
		// For now, we'll use default conductor endpoint
		return &S4TService{
			S4tClient: s4t_client,
			BaseURL:   "http://iotronic-conductor:8812", // Default conductor endpoint
		}, nil
	}
)

// Setup adds a controller that reconciles Request managed resources.
func Setup(mgr ctrl.Manager, o controller.Options) error {
	name := managed.ControllerName(v1alpha1.RequestGroupKind)

	cps := []managed.ConnectionPublisher{managed.NewAPISecretPublisher(mgr.GetClient(), mgr.GetScheme())}
	if o.Features.Enabled(features.EnableAlphaExternalSecretStores) {
		cps = append(cps, connection.NewDetailsManager(mgr.GetClient(), apisv1alpha1.StoreConfigGroupVersionKind))
	}

	r := managed.NewReconciler(mgr,
		resource.ManagedKind(v1alpha1.RequestGroupVersionKind),
		managed.WithExternalConnecter(&connector{
			kube:         mgr.GetClient(),
			usage:        resource.NewProviderConfigUsageTracker(mgr.GetClient(), &apisv1alpha1.ProviderConfigUsage{}),
			newServiceFn: newS4TService}),
		managed.WithLogger(o.Logger.WithValues("controller", name)),
		managed.WithPollInterval(o.PollInterval),
		managed.WithRecorder(event.NewAPIRecorder(mgr.GetEventRecorderFor(name))),
		managed.WithConnectionPublishers(cps...))

	return ctrl.NewControllerManagedBy(mgr).
		Named(name).
		WithOptions(o.ForControllerRuntime()).
		WithEventFilter(resource.DesiredStateChanged()).
		For(&v1alpha1.Request{}).
		Complete(ratelimiter.NewReconciler(name, r, o.GlobalRateLimiter))
}

type connector struct {
	kube         client.Client
	usage        resource.Tracker
	newServiceFn func(creds []byte, keystoneEndpoint string) (*S4TService, error)
}

func (c *connector) Connect(ctx context.Context, mg resource.Managed) (managed.ExternalClient, error) {
	_, ok := mg.(*v1alpha1.Request)
	if !ok {
		return nil, errors.New(errNotRequest)
	}

	if err := c.usage.Track(ctx, mg); err != nil {
		return nil, errors.Wrap(err, errTrackPCUsage)
	}

	pc_domain := &apisv1alpha1.ProviderConfig{}
	if err := c.kube.Get(ctx, types.NamespacedName{Name: "s4t-provider-domain"}, pc_domain); err != nil {
		return nil, errors.Wrap(err, errGetPC)
	}
	cd_domain := pc_domain.Spec.Credentials
	data_domain, err := resource.CommonCredentialExtractor(ctx, cd_domain.Source, c.kube, cd_domain.CommonCredentialSelectors)
	if err != nil {
		return nil, errors.Wrap(err, errGetCreds)
	}
	
	// Get Keystone endpoint from ProviderConfig, default to Kubernetes service
	keystoneEndpoint := pc_domain.Spec.KeystoneEndpoint
	if keystoneEndpoint == "" {
		keystoneEndpoint = "http://keystone.default.svc.cluster.local:5000/v3"
	}
	
	svc, err := c.newServiceFn(data_domain, keystoneEndpoint)
	if err != nil {
		return nil, errors.Wrap(err, errNewClient)
	}
	return &external{service: svc}, err
}

// An ExternalClient observes, then either creates, updates, or deletes an
// external resource to ensure it reflects the managed resource's desired state.
type external struct {
	// A 'client' used to connect to the external resource API. In practice this
	// would be something like an AWS SDK client.
	service *S4TService
}

// makeRESTCall makes a REST API call to the IoTronic service
func (c *external) makeRESTCall(method, path string, data interface{}) (*http.Response, error) {
	// Build URL using the service client's endpoint
	baseURL := fmt.Sprintf("http://iotronic-conductor.default.svc.cluster.local:%s", c.service.S4tClient.Port)
	url := fmt.Sprintf("%s/v1%s", baseURL, path)
	
	var reqBody io.Reader
	if data != nil {
		jsonData, err := json.Marshal(data)
		if err != nil {
			return nil, errors.Wrap(err, "failed to marshal request data")
		}
		reqBody = bytes.NewBuffer(jsonData)
	}

	req, err := http.NewRequest(method, url, reqBody)
	if err != nil {
		return nil, errors.Wrap(err, "failed to create request")
	}

	req.Header.Set("Content-Type", "application/json")
	if c.service.S4tClient.AuthToken != "" {
		req.Header.Set("X-Auth-Token", c.service.S4tClient.AuthToken)
	}

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, errors.Wrap(err, "failed to execute request")
	}

	return resp, nil
}

func (c *external) Observe(ctx context.Context, mg resource.Managed) (managed.ExternalObservation, error) {
	cr, ok := mg.(*v1alpha1.Request)
	if !ok {
		return managed.ExternalObservation{}, errors.New(errNotRequest)
	}

	fmt.Printf("Observing Request: %+v", cr)

	// Try to get request via REST API
	if cr.Spec.ForProvider.Uuid == "" {
		return managed.ExternalObservation{ResourceExists: false}, nil
	}

	resp, err := c.makeRESTCall("GET", fmt.Sprintf("/requests/%s", cr.Spec.ForProvider.Uuid), nil)
	if err != nil {
		log.Printf("Error getting request: %v", err)
		return managed.ExternalObservation{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode == http.StatusNotFound {
		return managed.ExternalObservation{ResourceExists: false}, nil
	}

	if resp.StatusCode != http.StatusOK {
		return managed.ExternalObservation{}, fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	var request map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&request); err != nil {
		return managed.ExternalObservation{}, errors.Wrap(err, "failed to decode response")
	}

	cr.Status.SetConditions(xpv1.Available())

	return managed.ExternalObservation{
		ResourceExists:   true,
		ResourceUpToDate: true,
		ConnectionDetails: managed.ConnectionDetails{},
	}, nil
}

func (c *external) Create(ctx context.Context, mg resource.Managed) (managed.ExternalCreation, error) {
	cr, ok := mg.(*v1alpha1.Request)
	if !ok {
		return managed.ExternalCreation{}, errors.New(errNotRequest)
	}

	fmt.Printf("Creating Request: %+v", cr)

	requestData := map[string]interface{}{
		"destination_uuid": cr.Spec.ForProvider.DestinationUuid,
		"action":           cr.Spec.ForProvider.Action,
	}
	if cr.Spec.ForProvider.Type != 0 {
		requestData["type"] = cr.Spec.ForProvider.Type
	}
	if cr.Spec.ForProvider.MainRequestUuid != "" {
		requestData["main_request_uuid"] = cr.Spec.ForProvider.MainRequestUuid
	}

	resp, err := c.makeRESTCall("POST", "/requests", requestData)
	if err != nil {
		log.Printf("Error creating request: %v", err)
		return managed.ExternalCreation{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated {
		bodyBytes := make([]byte, 1024)
		resp.Body.Read(bodyBytes)
		return managed.ExternalCreation{}, fmt.Errorf("unexpected status code: %d, body: %s", resp.StatusCode, string(bodyBytes))
	}

	var request map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&request); err != nil {
		return managed.ExternalCreation{}, errors.Wrap(err, "failed to decode response")
	}

	if uuid, ok := request["uuid"].(string); ok {
		cr.Spec.ForProvider.Uuid = uuid
		cr.Status.AtProvider.Uuid = uuid
	}

	return managed.ExternalCreation{
		ConnectionDetails: managed.ConnectionDetails{},
	}, nil
}

func (c *external) Update(ctx context.Context, mg resource.Managed) (managed.ExternalUpdate, error) {
	cr, ok := mg.(*v1alpha1.Request)
	if !ok {
		return managed.ExternalUpdate{}, errors.New(errNotRequest)
	}

	fmt.Printf("Updating Request: %+v", cr)

	requestData := map[string]interface{}{}
	if cr.Spec.ForProvider.Action != "" {
		requestData["action"] = cr.Spec.ForProvider.Action
	}
	if cr.Spec.ForProvider.Status != "" {
		requestData["status"] = cr.Spec.ForProvider.Status
	}

	resp, err := c.makeRESTCall("PATCH", fmt.Sprintf("/requests/%s", cr.Spec.ForProvider.Uuid), requestData)
	if err != nil {
		log.Printf("Error updating request: %v", err)
		return managed.ExternalUpdate{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return managed.ExternalUpdate{}, fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	return managed.ExternalUpdate{
		ConnectionDetails: managed.ConnectionDetails{},
	}, nil
}

func (c *external) Delete(ctx context.Context, mg resource.Managed) error {
	cr, ok := mg.(*v1alpha1.Request)
	if !ok {
		return errors.New(errNotRequest)
	}

	fmt.Printf("Deleting Request: %+v", cr)

	resp, err := c.makeRESTCall("DELETE", fmt.Sprintf("/requests/%s", cr.Spec.ForProvider.Uuid), nil)
	if err != nil {
		log.Printf("Error deleting request: %v", err)
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusNoContent && resp.StatusCode != http.StatusNotFound {
		return fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	return nil
}

