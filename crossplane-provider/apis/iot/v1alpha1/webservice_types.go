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

// WebserviceParameters are the configurable fields of a Webservice.
type WebserviceParameters struct {
	// +kubebuilder:validation:Immutable
	Uuid      string                 `json:"uuid,omitempty"`
	Name      string                 `json:"name"`
	Port      int                    `json:"port"`
	BoardUuid string               `json:"boardUuid,omitempty"`
	Secure    bool                 `json:"secure,omitempty"`
	Extra     runtime.RawExtension `json:"extra,omitempty"`
}

// WebserviceObservation are the observable fields of a Webservice.
type WebserviceObservation struct {
	Uuid string `json:"uuid,omitempty"`
	Name string `json:"name,omitempty"`
}

// A WebserviceSpec defines the desired state of a Webservice.
type WebserviceSpec struct {
	xpv1.ResourceSpec `json:",inline"`
	ForProvider       WebserviceParameters `json:"forProvider"`
}

// A WebserviceStatus represents the observed state of a Webservice.
type WebserviceStatus struct {
	xpv1.ResourceStatus `json:",inline"`
	AtProvider          WebserviceObservation `json:"atProvider,omitempty"`
	Uuid                string                `json:"uuid,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="READY",type="string",JSONPath=".status.conditions[?(@.type=='Ready')].status"
// +kubebuilder:printcolumn:name="SYNCED",type="string",JSONPath=".status.conditions[?(@.type=='Synced')].status"
// +kubebuilder:printcolumn:name="EXTERNAL-NAME",type="string",JSONPath=".metadata.annotations.crossplane\\.io/external-name"
// +kubebuilder:printcolumn:name="AGE",type="date",JSONPath=".metadata.creationTimestamp"
// +kubebuilder:resource:scope=Cluster,categories={crossplane,managed,s4t}

// Webservice is a Webservice resource.
type Webservice struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   WebserviceSpec   `json:"spec"`
	Status WebserviceStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// WebserviceList contains a list of Webservice
type WebserviceList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Webservice `json:"items"`
}

// Webservice type metadata.
var (
	WebserviceKind             = reflect.TypeOf(Webservice{}).Name()
	WebserviceGroupKind        = schema.GroupKind{Group: Group, Kind: WebserviceKind}.String()
	WebserviceKindAPIVersion   = WebserviceKind + "." + SchemeGroupVersion.String()
	WebserviceGroupVersionKind = SchemeGroupVersion.WithKind(WebserviceKind)
)

func init() {
	SchemeBuilder.Register(&Webservice{}, &WebserviceList{})
}

