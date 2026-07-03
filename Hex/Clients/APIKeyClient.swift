//
//  APIKeyClient.swift
//  Hex
//

import Dependencies
import DependenciesMacros
import Foundation
import Security

private let keychainService = "com.kitlangton.Hex"
private let openAIAccount = "openai-api-key"

enum KeychainStore {
  static func read(account: String) -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var result: AnyObject?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess, let data = result as? Data else { return nil }
    return String(data: data, encoding: .utf8)
  }

  static func save(account: String, value: String) throws {
    let data = Data(value.utf8)
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
    ]
    let attributes: [String: Any] = [kSecValueData as String: data]
    let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if status == errSecItemNotFound {
      var addQuery = query
      addQuery[kSecValueData as String] = data
      addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
      guard SecItemAdd(addQuery as CFDictionary, nil) == errSecSuccess else {
        throw KeychainError.saveFailed
      }
    } else if status != errSecSuccess {
      throw KeychainError.saveFailed
    }
  }

  static func delete(account: String) throws {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: account,
    ]
    let status = SecItemDelete(query as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw KeychainError.deleteFailed
    }
  }
}

enum KeychainError: Error {
  case saveFailed
  case deleteFailed
}

@DependencyClient
struct APIKeyClient {
  var getOpenAIKey: @Sendable () -> String? = { nil }
  var setOpenAIKey: @Sendable (String?) throws -> Void = { _ in }
}

extension APIKeyClient: DependencyKey {
  static let liveValue = Self(
    getOpenAIKey: { KeychainStore.read(account: openAIAccount) },
    setOpenAIKey: { value in
      if let value, !value.isEmpty {
        try KeychainStore.save(account: openAIAccount, value: value)
      } else {
        try KeychainStore.delete(account: openAIAccount)
      }
    }
  )

  static let testValue = Self(
    getOpenAIKey: { nil },
    setOpenAIKey: { _ in }
  )
}

extension DependencyValues {
  var apiKey: APIKeyClient {
    get { self[APIKeyClient.self] }
    set { self[APIKeyClient.self] = newValue }
  }
}
