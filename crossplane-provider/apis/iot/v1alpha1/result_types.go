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
	"k8s.io/apimachinery/pkg/runtime/schema"
)

// ResultParameters are the configurable fields of a Result.
// Note: Results are typically read-only resources created by Stack4Things
type ResultParameters struct {
	// +kubebuilder:validation:Immutable
	Uuid        string `json:"uuid,omitempty"`
	BoardUuid   string `json:"boardUuid,omitempty"`
	RequestUuid string `json:"requestUuid,omitempty"`
	Result      string `json:"result,omitempty"`
	Message     string `json:"message,omitempty"`
}

// ResultObservation are the observable fields of a Result.
type ResultObservation struct {
	Uuid        string `json:"uuid,omitempty"`
	BoardUuid   string `json:"boardUuid,omitempty"`
	RequestUuid string `json:"requestUuid,omitempty"`
	Result      string `json:"result,omitempty"`
	Message     string `json:"message,omitempty"`
}

// A ResultSpec defines the desired state of a Result.
type ResultSpec struct {
	xpv1.ResourceSpec `json:",inline"`
	ForProvider        ResultParameters `json:"forProvider"`
}

// A ResultStatus represents the observed state of a Result.
type ResultStatus struct {
	xpv1.ResourceStatus `json:",inline"`
	AtProvider          ResultObservation `json:"atProvider,omitempty"`
	Uuid                string            `json:"uuid,omitempty"`
}

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="READY",type="string",JSONPath=".status.conditions[?(@.type=='Ready')].status"
// +kubebuilder:printcolumn:name="SYNCED",type="string",JSONPath=".status.conditions[?(@.type=='Synced')].status"
// +kubebuilder:printcolumn:name="EXTERNAL-NAME",type="string",JSONPath=".metadata.annotations.crossplane\\.io/external-name"
// +kubebuilder:printcolumn:name="AGE",type="date",JSONPath=".metadata.creationTimestamp"
// +kubebuilder:resource:scope=Cluster,categories={crossplane,managed,s4t}

// Result is a Result resource (read-only).
type Result struct {
	metav1.TypeMeta   `json:",inline"`
	metav1.ObjectMeta `json:"metadata,omitempty"`

	Spec   ResultSpec   `json:"spec"`
	Status ResultStatus `json:"status,omitempty"`
}

// +kubebuilder:object:root=true

// ResultList contains a list of Result
type ResultList struct {
	metav1.TypeMeta `json:",inline"`
	metav1.ListMeta `json:"metadata,omitempty"`
	Items           []Result `json:"items"`
}

// Result type metadata.
var (
	ResultKind             = reflect.TypeOf(Result{}).Name()
	ResultGroupKind        = schema.GroupKind{Group: Group, Kind: ResultKind}.String()
	ResultKindAPIVersion   = ResultKind + "." + SchemeGroupVersion.String()
	ResultGroupVersionKind = SchemeGroupVersion.WithKind(ResultKind)
)

func init() {
	SchemeBuilder.Register(&Result{}, &ResultList{})
}

