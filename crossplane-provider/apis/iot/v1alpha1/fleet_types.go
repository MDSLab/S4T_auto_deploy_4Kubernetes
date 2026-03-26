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

	xpv1 "github.com/crossplane/crossplane-runtime/apis/common/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// FleetParameters are the configurable fields of a Fleet.
type FleetParameters struct {
	// +kubebuilder:validation:Immutable
	Uuid        string               `json:"uuid,omitempty"`
	Name        string               `json:"name"`
	Description string               `json:"description,omitempty"`
	Project     string               `json:"project,omitempty"`
	Extra       runtime.RawExtension `json:"extra,omitempty"`
}

// FleetObservation are the observable fields of a Fleet.
type FleetObservation struct {
	Uuid string `json:"uuid,omitempty"`
	Name string `json:"name,omitempty"`
}

// A FleetSpec defines the desired state of a Fleet.
type FleetSpec struct {
	xpv1.ResourceSpec `json:",inline"`
	ForProvider       FleetParameters `json:"forProvider"`
}

// A FleetStatus represents the observed state of a Fleet.
type FleetStatus struct {
	xpv1.ResourceStatus `json:",inline"`
	AtProvider          FleetObservation `json:"atProvider,omitempty"`
	Uuid                string          `json:"uuid,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="READY",type="string",JSONPath=".status.conditions[?(@.type=='Ready')].status"
// +kubebuilder:printcolumn:name="SYNCED",type="string",JSONPath=".status.conditions[?(@.type=='Synced')].status"
// +kubebuilder:printcolumn:name="EXTERNAL-NAME",type="string",JSONPath=".metadata.annotations.crossplane\\.io/external-name"
// +kubebuilder:printcolumn:name="AGE",type="date",JSONPath=".metadata.creationTimestamp"
// +kubebuilder:resource:scope=Cluster,categories={crossplane,managed,s4t}

// Fleet is a Fleet resource.
type Fleet struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   FleetSpec   `json:"spec"`
	Status FleetStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// FleetList contains a list of Fleet
type FleetList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Fleet `json:"items"`
}

// Fleet type metadata.
var (
	FleetKind             = reflect.TypeOf(Fleet{}).Name()
	FleetGroupKind        = schema.GroupKind{Group: Group, Kind: FleetKind}.String()
	FleetKindAPIVersion   = FleetKind + "." + SchemeGroupVersion.String()
	FleetGroupVersionKind = SchemeGroupVersion.WithKind(FleetKind)
)

func init() {
	SchemeBuilder.Register(&Fleet{}, &FleetList{})
}

