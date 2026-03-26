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

package service

import (
	"strings"
	"context"
	"encoding/json"
	"fmt"
	"log"
	"os"
	xpv1 "github.com/crossplane/crossplane-runtime/apis/common/v1"
	"github.com/pkg/errors"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"
	"sigs.k8s.io/controller-runtime/pkg/client"

	s4t "github.com/MIKE9708/s4t-sdk-go/pkg/api"
	read_config "github.com/MIKE9708/s4t-sdk-go/pkg/read_conf"

	services "github.com/MIKE9708/s4t-sdk-go/pkg/api/data/service"

	"github.com/crossplane/crossplane-runtime/pkg/connection"
	"github.com/crossplane/crossplane-runtime/pkg/controller"
	"github.com/crossplane/crossplane-runtime/pkg/event"
	"github.com/crossplane/crossplane-runtime/pkg/ratelimiter"
	"github.com/crossplane/crossplane-runtime/pkg/reconciler/managed"
	"github.com/crossplane/crossplane-runtime/pkg/resource"

	"github.com/crossplane/provider-s4t/apis/iot/v1alpha1"
	apisv1alpha1 "github.com/crossplane/provider-s4t/apis/v1alpha1"
	"github.com/crossplane/provider-s4t/internal/features"
)

const (
	errNotService   = "managed resource is not a Service custom resource"
	errTrackPCUsage = "cannot track ProviderConfig usage"
	errGetPC        = "cannot get ProviderConfig"
	errGetCreds     = "cannot get credentials"

	errNewClient = "cannot create new Service"
)

type S4TService struct {
	S4tClient *s4t.Client
}

var (
	newS4TService = func(creds []byte, keystoneEndpoint string) (*S4TService, error) {
		var result map[string]string
		err := json.Unmarshal(creds, &result)
		if err != nil {
			return nil, errors.Wrap(err, errNewClient)
		}
		
		// Set Keystone endpoint via environment variable (OS_AUTH_URL)
		if keystoneEndpoint != "" {
			os.Setenv("OS_AUTH_URL", keystoneEndpoint)
		} else {
			os.Setenv("OS_AUTH_URL", "http://keystone.default.svc.cluster.local:5000/v3")
		}
		
		// Also set other OpenStack env vars that SDK might need
		os.Setenv("OS_IDENTITY_API_VERSION", "3")
		
		auth_req := read_config.FormatAuthRequ(
			result["username"],
			result["password"],
			result["domain"],
		)
		// Ensure OS_AUTH_URL is still set (in case FormatAuthRequ cleared it)
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
		
		return &S4TService{
			S4tClient: s4t_client,
		}, err
	}
)

func Setup(mgr ctrl.Manager, o controller.Options) error {
	name := managed.ControllerName(v1alpha1.ServiceGroupKind)

	cps := []managed.ConnectionPublisher{managed.NewAPISecretPublisher(mgr.GetClient(), mgr.GetScheme())}
	if o.Features.Enabled(features.EnableAlphaExternalSecretStores) {
		cps = append(cps, connection.NewDetailsManager(mgr.GetClient(), apisv1alpha1.StoreConfigGroupVersionKind))
	}

	r := managed.NewReconciler(mgr,
		resource.ManagedKind(v1alpha1.ServiceGroupVersionKind),
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
		For(&v1alpha1.Service{}).
		Complete(ratelimiter.NewReconciler(name, r, o.GlobalRateLimiter))
}

type connector struct {
	kube         client.Client
	usage        resource.Tracker
	newServiceFn func(creds []byte, keystoneEndpoint string) (*S4TService, error)
}

func (c *connector) Connect(ctx context.Context, mg resource.Managed) (managed.ExternalClient, error) {
	_, ok := mg.(*v1alpha1.Service)
	if !ok {
		return nil, errors.New(errNotService)
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

func (c *external) Observe(ctx context.Context, mg resource.Managed) (managed.ExternalObservation, error) {
	cr, ok := mg.(*v1alpha1.Service)
	if !ok {
		return managed.ExternalObservation{}, errors.New(errNotService)
	}
	fmt.Printf("Observing: %+v", cr)
	service, err := c.service.S4tClient.GetService(cr.Spec.ForProvider.Uuid)
	if err != nil {
		log.Printf("####ERROR-LOG#### Error s4t client Service Get %q", err)
		return managed.ExternalObservation{}, err
	}

	if service.Uuid == "" {
		return managed.ExternalObservation{ResourceExists: false}, nil
	}

	cr.Status.SetConditions(xpv1.Available())

	return managed.ExternalObservation{
		ResourceExists:    true,
		ResourceUpToDate:  true,
		ConnectionDetails: managed.ConnectionDetails{},
	}, nil
}

func (c *external) Create(ctx context.Context, mg resource.Managed) (managed.ExternalCreation, error) {
	cr, ok := mg.(*v1alpha1.Service)
	if !ok {
		return managed.ExternalCreation{}, errors.New(errNotService)
	}

	fmt.Printf("Creating: %+v", cr)

	srvc := services.Service{
		Name:     cr.Spec.ForProvider.Name,
		Port:     cr.Spec.ForProvider.Port,
		Protocol: cr.Spec.ForProvider.Protocol,
	}
	service, err := c.service.S4tClient.CreateService(srvc)
	if err != nil {
		log.Printf("####ERROR-LOG#### Error s4t client Service Create %q", err)
		return managed.ExternalCreation{}, errors.New(errNewClient)
	}

	cr.Spec.ForProvider.Uuid = service.Uuid

	return managed.ExternalCreation{
		// Optionally return any details that may be required to connect to the
		// external resource. These will be stored as the connection secret.
		ConnectionDetails: managed.ConnectionDetails{},
	}, nil
}

func (c *external) Update(ctx context.Context, mg resource.Managed) (managed.ExternalUpdate, error) {
	cr, ok := mg.(*v1alpha1.Service)
	if !ok {
		return managed.ExternalUpdate{}, errors.New(errNotService)
	}

	fmt.Printf("Updating: %+v", cr)
	req := map[string]interface{}{
		"name":     cr.Spec.ForProvider.Name,
		"port":     cr.Spec.ForProvider.Port,
		"protocol": cr.Spec.ForProvider.Protocol,
	}
	log.Printf("\n\n####ERROR-LOG########## \n\n%s\n\n", cr.Spec.ForProvider.Uuid)
	_, err := c.service.S4tClient.PatchService(cr.Spec.ForProvider.Uuid, req)
	if err != nil {
		log.Printf("####ERROR-LOG#### Error s4t client Plugin Update %q", err)
		return managed.ExternalUpdate{}, errors.New(errNewClient)
	}

	return managed.ExternalUpdate{
		ConnectionDetails: managed.ConnectionDetails{},
	}, nil
}

func (c *external) Delete(ctx context.Context, mg resource.Managed) error {
	cr, ok := mg.(*v1alpha1.Service)
	if !ok {
		return errors.New(errNotService)
	}

	fmt.Printf("Deleting: %+v", cr)

	log.Printf("\n\n####ERROR-LOG#################\n %s \n\n", cr.Spec.ForProvider.Uuid)
	err := c.service.S4tClient.DeleteService(cr.Spec.ForProvider.Uuid)
	if err != nil {
		log.Printf("####ERROR-LOG#### Error s4t client Service Delete %q", err)
	}
	return err
}
