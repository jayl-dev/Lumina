/**
 * @file tests/unit/test_crypto.cpp
 * @brief Regression tests for certificate authentication.
 */

#include <gtest/gtest.h>

#include "src/crypto.h"

namespace {
  crypto::x509_t make_leaf_signed_by(const crypto::creds_t &leaf_identity, const crypto::creds_t &issuer_identity) {
    auto leaf_identity_cert = crypto::x509(leaf_identity.x509);
    auto issuer_cert = crypto::x509(issuer_identity.x509);
    auto issuer_key = crypto::pkey(issuer_identity.pkey);

    crypto::x509_t leaf {X509_new()};
    if (!leaf || !leaf_identity_cert || !issuer_cert || !issuer_key) {
      return nullptr;
    }

    if (X509_set_version(leaf.get(), 2) != 1 ||
        ASN1_INTEGER_set(X509_get_serialNumber(leaf.get()), 1) != 1 ||
        X509_gmtime_adj(X509_get_notBefore(leaf.get()), 0) == nullptr ||
        X509_gmtime_adj(X509_get_notAfter(leaf.get()), 3600) == nullptr ||
        X509_set_pubkey(leaf.get(), X509_get0_pubkey(leaf_identity_cert.get())) != 1 ||
        X509_set_subject_name(leaf.get(), X509_get_subject_name(leaf_identity_cert.get())) != 1 ||
        X509_set_issuer_name(leaf.get(), X509_get_subject_name(issuer_cert.get())) != 1 ||
        X509_sign(leaf.get(), issuer_key.get(), EVP_sha256()) <= 0) {
      return nullptr;
    }

    return leaf;
  }
}  // namespace

TEST(CertificateAuthenticationTest, RejectsLeafFromUntrustedIssuer) {
  const auto paired_client = crypto::gen_creds("paired-client", 2048);
  const auto attacker_root = crypto::gen_creds("attacker-root", 2048);
  const auto attacker_leaf_identity = crypto::gen_creds("attacker-leaf", 2048);

  auto attacker_leaf = make_leaf_signed_by(attacker_leaf_identity, attacker_root);
  ASSERT_NE(attacker_leaf, nullptr);

  crypto::cert_chain_t paired_clients;
  paired_clients.add(crypto::x509(paired_client.x509));

  // CVE-2026-32253 was caused by treating
  // X509_V_ERR_UNABLE_TO_GET_ISSUER_CERT_LOCALLY as a successful verification.
  EXPECT_NE(paired_clients.verify(attacker_leaf.get()), nullptr);
}

TEST(CertificateAuthenticationTest, AcceptsPairedCertificate) {
  const auto paired_client = crypto::gen_creds("paired-client", 2048);
  auto presented_certificate = crypto::x509(paired_client.x509);
  ASSERT_NE(presented_certificate, nullptr);

  crypto::cert_chain_t paired_clients;
  paired_clients.add(crypto::x509(paired_client.x509));

  EXPECT_EQ(paired_clients.verify(presented_certificate.get()), nullptr);
}
