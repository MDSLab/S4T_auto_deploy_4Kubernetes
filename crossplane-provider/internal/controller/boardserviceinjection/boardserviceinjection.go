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

package boardserviceinjection

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
	"github.com/crossplane/provider-s4t/apis/iot/v1alpha1"
	apisv1alpha1 "github.com/crossplane/provider-s4t/apis/v1alpha1"
	"github.com/crossplane/provider-s4t/internal/features"
	"github.com/pkg/errors"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"
)

const (
	errNotBoardServiceInjection = "managed resource is not a BoardServiceInjection custom resource"
	errTrackPCUsage             = "cannot track ProviderConfig usage"
	errGetPC                    = "cannot get ProviderConfig"
	errGetCreds                 = "cannot get credentials"
	errNewClient                = "cannot create new Service"
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
		return &S4TService{
			S4tClient: s4t_client,
			BaseURL:   "http://iotronic-conductor:8812",
		}, nil
	}
)

// Setup adds a controller that reconciles BoardServiceInjection managed resources.
func Setup(mgr ctrl.Manager, o controller.Options) error {
	name := managed.ControllerName(v1alpha1.BoardServiceInjectionGroupKind)

	cps := []managed.ConnectionPublisher{managed.NewAPISecretPublisher(mgr.GetClient(), mgr.GetScheme())}
	if o.Features.Enabled(features.EnableAlphaExternalSecretStores) {
		cps = append(cps, connection.NewDetailsManager(mgr.GetClient(), apisv1alpha1.StoreConfigGroupVersionKind))
	}

	r := managed.NewReconciler(mgr,
		resource.ManagedKind(v1alpha1.BoardServiceInjectionGroupVersionKind),
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
		For(&v1alpha1.BoardServiceInjection{}).
		Complete(ratelimiter.NewReconciler(name, r, o.GlobalRateLimiter))
}

// A connector is expected to produce an ExternalClient when its Connect method
// is called.
type connector struct {
	kube         client.Client
	usage        resource.Tracker
	newServiceFn func(creds []byte, keystoneEndpoint string) (*S4TService, error)
}

// Connect typically produces an ExternalClient by:
// 1. Tracking that the managed resource is using a ProviderConfig.
// 2. Getting the managed resource's ProviderConfig.
// 3. Getting the credentials specified by the ProviderConfig.
// 4. Using the credentials to form a client.
func (c *connector) Connect(ctx context.Context, mg resource.Managed) (managed.ExternalClient, error) {
	_, ok := mg.(*v1alpha1.BoardServiceInjection)
	if !ok {
		return nil, errors.New(errNotBoardServiceInjection)
	}

	if err := c.usage.Track(ctx, mg); err != nil {
		return nil, errors.Wrap(err, errTrackPCUsage)
	}
	// cr.GetProviderConfigReference().Name
	pc_domain := &apisv1alpha1.ProviderConfig{}
	if err := c.kube.Get(ctx, types.NamespacedName{Name: "s4t-provider-domain"}, pc_domain); err != nil {
		return nil, errors.Wrap(err, errGetPC)
	}
	cd_domain := pc_domain.Spec.Credentials
	data_domain, err := resource.CommonCredentialExtractor(ctx, cd_domain.Source, c.kube, cd_domain.CommonCredentialSelectors)
	if err != nil {
		return nil, errors.Wrap(err, errGetCreds)
	}
	log.Printf("\n\n####ERROR-LOG##################################################\n\n")
	log.Println(string(data_domain))
	log.Printf("\n\n####ERROR-LOG##################################################\n\n")
	
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

// Observe verifies if a service is actually exposed on a board.
// API: GET /v1/boards/{board_uuid}/services
// Response: {"exposed": [{"service": "uuid", "public_port": 50024, ...}]}
// Returns ResourceExists=true if the service is found in the board's exposed services list.
func (c *external) Observe(ctx context.Context, mg resource.Managed) (managed.ExternalObservation, error) {
	cr, ok := mg.(*v1alpha1.BoardServiceInjection)
	if !ok {
		return managed.ExternalObservation{}, errors.New(errNotBoardServiceInjection)
	}

	fmt.Printf("Observing BoardServiceInjection: %+v", cr)

	// Get board detail to check if it exists
	board, err := c.service.S4tClient.GetBoardDetail(cr.Spec.ForProvider.BoardUuid)
	if err != nil {
		log.Printf("####ERROR-LOG#### Error s4t client Board Get %q", err)
		return managed.ExternalObservation{}, err
	}

	if board.Uuid == "" {
		return managed.ExternalObservation{ResourceExists: false}, nil
	}

	// Check if service is exposed on board via REST API
	resp, err := c.makeRESTCall("GET", fmt.Sprintf("/boards/%s/services", cr.Spec.ForProvider.BoardUuid), nil)
	if err != nil {
		log.Printf("Error getting board services: %v", err)
		return managed.ExternalObservation{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		return managed.ExternalObservation{ResourceExists: false}, nil
	}

	var exposedCollection map[string]interface{}
	if err := json.NewDecoder(resp.Body).Decode(&exposedCollection); err != nil {
		return managed.ExternalObservation{}, errors.Wrap(err, "failed to decode response")
	}

	// Check if our service is in the exposed list
	exposed, ok := exposedCollection["exposed"].([]interface{})
	if !ok {
		return managed.ExternalObservation{ResourceExists: false}, nil
	}

	found := false
	for _, exp := range exposed {
		expMap, ok := exp.(map[string]interface{})
		if !ok {
			continue
		}
		if service, ok := expMap["service"].(string); ok && service == cr.Spec.ForProvider.ServiceUuid {
			found = true
			break
		}
	}

	if !found {
		return managed.ExternalObservation{ResourceExists: false}, nil
	}

	cr.Status.SetConditions(xpv1.Available())

	return managed.ExternalObservation{
		ResourceExists:   true,
		ResourceUpToDate: true,
		ConnectionDetails: managed.ConnectionDetails{},
	}, nil
}

// Create exposes a service on a board via IoTronic API.
// API: POST /v1/boards/{board_uuid}/services/{service_uuid}/action
// Request Body: {"action": "ServiceEnable"}
// Response: 200 OK on success
// Prerequisites:
//   - Board must be online (status='online', Lightning Rod connected)
//   - Service must exist in database
//   - Board must have an active wagent assigned
// The service will be exposed on a random public port (typically in range 50000-50100)
func (c *external) Create(ctx context.Context, mg resource.Managed) (managed.ExternalCreation, error) {
	cr, ok := mg.(*v1alpha1.BoardServiceInjection)
	if !ok {
		return managed.ExternalCreation{}, errors.New(errNotBoardServiceInjection)
	}

	fmt.Printf("Creating BoardServiceInjection: %+v", cr)

	// Expose service on board via REST API
	// POST /v1/boards/{uuid}/services/{service_uuid}/action with action "ServiceEnable"
	serviceData := map[string]interface{}{
		"action": "ServiceEnable",
	}
	
	resp, err := c.makeRESTCall("POST", fmt.Sprintf("/boards/%s/services/%s/action", cr.Spec.ForProvider.BoardUuid, cr.Spec.ForProvider.ServiceUuid), serviceData)
	if err != nil {
		log.Printf("Error exposing service on board: %v", err)
		return managed.ExternalCreation{}, err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		bodyBytes := make([]byte, 1024)
		resp.Body.Read(bodyBytes)
		return managed.ExternalCreation{}, fmt.Errorf("unexpected status code: %d, body: %s", resp.StatusCode, string(bodyBytes))
	}

	log.Printf("Service %s exposed on board %s", cr.Spec.ForProvider.ServiceUuid, cr.Spec.ForProvider.BoardUuid)

	return managed.ExternalCreation{
		ConnectionDetails: managed.ConnectionDetails{},
	}, nil
}

// Update is a no-op for BoardServiceInjection.
// Service exposures cannot be updated; they must be deleted and recreated.
func (c *external) Update(ctx context.Context, mg resource.Managed) (managed.ExternalUpdate, error) {
	return managed.ExternalUpdate{
		ConnectionDetails: managed.ConnectionDetails{},
	}, nil
}

// Delete removes an exposed service from a board via IoTronic API.
// API: POST /v1/boards/{board_uuid}/services/{service_uuid}/action
// Request Body: {"action": "ServiceDisable"}
// Response: 200 OK on success
func (c *external) Delete(ctx context.Context, mg resource.Managed) error {
	cr, ok := mg.(*v1alpha1.BoardServiceInjection)
	if !ok {
		return errors.New(errNotBoardServiceInjection)
	}

	fmt.Printf("Deleting BoardServiceInjection: %+v", cr)

	// Remove service from board via REST API
	// POST /v1/boards/{uuid}/services/{service_uuid}/action with action "ServiceDisable"
	serviceData := map[string]interface{}{
		"action": "ServiceDisable",
	}
	
	resp, err := c.makeRESTCall("POST", fmt.Sprintf("/boards/%s/services/%s/action", cr.Spec.ForProvider.BoardUuid, cr.Spec.ForProvider.ServiceUuid), serviceData)
	if err != nil {
		log.Printf("Error removing service from board: %v", err)
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK && resp.StatusCode != http.StatusNoContent {
		return fmt.Errorf("unexpected status code: %d", resp.StatusCode)
	}

	log.Printf("Service %s removed from board %s", cr.Spec.ForProvider.ServiceUuid, cr.Spec.ForProvider.BoardUuid)

	return nil
}
