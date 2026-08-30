//! Rust bindings for the Kubernetes Multi-Cluster Services (MCS) API,
//! API group `multicluster.x-k8s.io`.
//!
//! The types are generated from the upstream CRD manifests of
//! [kubernetes-sigs/mcs-api](https://github.com/kubernetes-sigs/mcs-api) with
//! [kopium](https://github.com/kube-rs/kopium).
//!
//! This crate is versioned independently of upstream; the upstream release
//! the bindings correspond to is [`MCS_API_VERSION`].
//!
//! Types are scoped by API group and version, so `ServiceImport` lives at
//! [`multicluster_x_k8s_io::v1beta1::ServiceImport`].

pub mod multicluster_x_k8s_io;

/// The upstream [kubernetes-sigs/mcs-api] release the bindings in this crate are
/// generated from.
///
/// [kubernetes-sigs/mcs-api]: https://github.com/kubernetes-sigs/mcs-api
pub const MCS_API_VERSION: &str = "v0.5.2";
