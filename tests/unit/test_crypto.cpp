/**
 * @file tests/unit/test_crypto.cpp
 * @brief Regression tests for certificate authentication.
 */

#include <gtest/gtest.h>

#include "../certificate_test_utils.h"
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

TEST(CryptoTest, GeneratedCredentialsExposeSubjectAndVerifySignatures) {
  constexpr std::string_view common_name = "Lumina Test Host";
  constexpr std::string_view payload = "payload";

  auto creds = crypto::gen_creds(common_name, 2048);
  ASSERT_FALSE(creds.x509.empty());
  ASSERT_FALSE(creds.pkey.empty());

  auto cert = crypto::x509(creds.x509);
  auto pkey = crypto::pkey(creds.pkey);
  ASSERT_NE(cert.get(), nullptr);
  ASSERT_NE(pkey.get(), nullptr);

  const auto subject = X509_get_subject_name(cert.get());
  ASSERT_NE(subject, nullptr);

  const auto common_name_index = X509_NAME_get_index_by_NID(subject, NID_commonName, -1);
  ASSERT_GE(common_name_index, 0);

  const auto common_name_entry = X509_NAME_get_entry(subject, common_name_index);
  ASSERT_NE(common_name_entry, nullptr);

  const auto common_name_data = X509_NAME_ENTRY_get_data(common_name_entry);
  ASSERT_NE(common_name_data, nullptr);

  const std::string_view parsed_common_name {
    reinterpret_cast<const char *>(ASN1_STRING_get0_data(common_name_data)),
    static_cast<std::size_t>(ASN1_STRING_length(common_name_data))
  };
  ASSERT_EQ(parsed_common_name, common_name);

  ASSERT_FALSE(crypto::signature(cert).empty());

  const auto signature = crypto::sign256(pkey, payload);
  ASSERT_FALSE(signature.empty());
  ASSERT_TRUE(crypto::verify256(cert, payload, {reinterpret_cast<const char *>(signature.data()), signature.size()}));
}

TEST(CryptoTest, CertificateChainRequiresExactPairedIdentity) {
  const auto issuer_credentials = test_utils::certificates::generate_ca_credentials();
  const auto derived_credentials = test_utils::certificates::generate_derived_leaf(issuer_credentials);
  auto paired_certificate = crypto::x509(issuer_credentials.x509);
  auto derived_certificate = crypto::x509(derived_credentials.x509);

  crypto::cert_chain_t certificate_chain;
  certificate_chain.add(crypto::x509(issuer_credentials.x509));

  EXPECT_EQ(certificate_chain.verify(paired_certificate.get()), nullptr);
  EXPECT_NE(certificate_chain.verify(derived_certificate.get()), nullptr);
}
