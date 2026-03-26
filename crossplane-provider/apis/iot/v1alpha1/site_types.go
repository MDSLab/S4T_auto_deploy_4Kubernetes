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

package v1alpha1

import (
	"reflect"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"

	xpv1 "github.com/crossplane/crossplane-runtime/apis/common/v1"
)

// SiteParameters are the configurable fields of a Site.
type SiteParameters struct {
	// +kubebuilder:validation:Immutable
	Uuid string `json:"uuid,omitempty"`
	// +kubebuilder:validation:Required
	Name string `json:"name"`
	// Description of the site
	Description string `json:"description,omitempty"`
	// Location information for the site
	Location string `json:"location,omitempty"`
	// Site configuration parameters
	Config map[string]string `json:"config,omitempty"`
	// Parent site UUID for hierarchical multisite structure
	ParentSite string `json:"parentSite,omitempty"`
}

// SiteObservation are the observable fields of a Site.
type SiteObservation struct {
	Uuid        string `json:"uuid,omitempty"`
	Name        string `json:"name,omitempty"`
	Status      string `json:"status,omitempty"`
	DeviceCount int    `json:"deviceCount,omitempty"`
}

// A SiteSpec defines the desired state of a Site.
type SiteSpec struct {
	xpv1.ResourceSpec `json:",inline"`
	ForProvider       SiteParameters `json:"forProvider"`
}

// A SiteStatus represents the observed state of a Site.
type SiteStatus struct {
	xpv1.ResourceStatus `json:",inline"`
	AtProvider          SiteObservation `json:"atProvider,omitempty"`
	Uuid                string          `json:"uuid,omitempty"`
	Status              string          `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// A Site is a resource type for managing Stack4Things multisite deployments.
// +kubebuilder:printcolumn:name="Site Name",type=string,JSONPath=".spec.forProvider.name"
// +kubebuilder:printcolumn:name="Location",type=string,JSONPath=".spec.forProvider.location"
// +kubebuilder:printcolumn:name="Status",type=string,JSONPath=".status.status"
// +kubebuilder:printcolumn:name="READY",type="string",JSONPath=".status.conditions[?(@.type=='Ready')].status"
// +kubebuilder:printcolumn:name="SYNCED",type="string",JSONPath=".status.conditions[?(@.type=='Synced')].status"
// +kubebuilder:printcolumn:name="EXTERNAL-NAME",type="string",JSONPath=".metadata.annotations.crossplane\\.io/external-name"
// +kubebuilder:printcolumn:name="AGE",type="date",JSONPath=".metadata.creationTimestamp"
// +kubebuilder:subresource:status
// +kubebuilder:resource:scope=Cluster,categories={crossplane,managed,s4t}
// +k8s:deepcopy-gen:interfaces=k8s.io/apimachinery/pkg/runtime.Object
type Site struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   SiteSpec   `json:"spec"`
	Status SiteStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// SiteList contains a list of Site
type SiteList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Site `json:"items"`
}

// Site type metadata.
var (
	SiteKind             = reflect.TypeOf(Site{}).Name()
	SiteGroupKind        = schema.GroupKind{Group: Group, Kind: SiteKind}.String()
	SiteKindAPIVersion   = SiteKind + "." + SchemeGroupVersion.String()
	SiteGroupVersionKind = SchemeGroupVersion.WithKind(SiteKind)
)

func init() {
	SchemeBuilder.Register(&Site{}, &SiteList{})
}

