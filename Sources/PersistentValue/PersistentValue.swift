//
//  PersistentValue.swift
//
//  Created by Christopher G Prince on 7/26/17.
//  Copyright © 2017 roster. All rights reserved.
//

import SwiftyUserDefaults
import KeychainAccess
import Foundation

public enum PersistentValueStorage {
    case userDefaults
    case keyChain
    
    // Similar to userDefaults, but stored in specific app file.
    case file
}

public class PersistentValueKeychain {
    // Previously, `keychainService` was the same across some variants of the app I was building -- however, this generated a problem -- it caused sharing of keychain values across the app store and beta apps! See also (https://stackoverflow.com/questions/47272209/sharing-of-keychain-values-across-apps-with-similar-bundle-ids)

    // By default, the bundle identifier. Change this to a consistent value if you want to share with an extension.
    public static var keychainService = Bundle.main.bundleIdentifier!
    
    // Set this if you want to share keychain items with an extension. See also https://developer.apple.com/documentation/security/keychain_services/keychain_items/sharing_access_to_keychain_items_among_a_collection_of_apps
    public static var accessGroup: String?
    
    static var keychain: Keychain {
        if let accessGroup = accessGroup {
            return Keychain(service: keychainService, accessGroup: accessGroup)
        }
        else {
            return Keychain(service: keychainService)
        }
    }
}

public class PersistentValueFile {
    // for PersistentValueStorage.file; directory is the Documents directory for the app.
    static let defaultBackingFile = "PersistentValues"
    
    // Change this at app launch if you want to change the backing file used for PersistentValueStorage.file
    public static var backingFile = defaultBackingFile

    // In case you want to use a shared container, this is intended for a application group identifier directory. https://developer.apple.com/documentation/bundleresources/entitlements/com_apple_security_application-groups
    // If set, this is used rather than the standard Documents directory for an app.
    public static var alternativeDocumentsDirectory: String?
    
    static var filePath: String {
        let documentsPath: String
        
        if let alternativeDocumentsDirectory = alternativeDocumentsDirectory {
            documentsPath = alternativeDocumentsDirectory
        }
        else {
            documentsPath = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true)[0]
        }
        
        return documentsPath + "/" + PersistentValueFile.backingFile
    }
    
    static func write(dictionary: Dictionary<String, Any>) -> Bool {
        let data = NSKeyedArchiver.archivedData(withRootObject: dictionary)
        let url = URL(fileURLWithPath: filePath, isDirectory: false)
        
        do {
            // The .noFileProtection option is so this file can be used when the app is launched in the background-- see (https://forums.developer.apple.com/thread/15685)
            // Using .atomic option because otherwise, if writes are carried out quickly, we seem to run into problems. E.g., when I run my unit test cases, they fail without this.
            var options: Data.WritingOptions = [.atomic]
            #if !os(OSX)
                options.update(with: .noFileProtection)
            #endif
            
            try data.write(to: url, options: options)
        } catch (let error) {
            print("ERROR: \(error)")
            return false
        }
        
        return true
    }
    
    static func read() -> Dictionary<String, Any>? {
        let url = URL(fileURLWithPath: filePath, isDirectory: false)
        var data: Data!
        
        do {
            data = try Data(contentsOf: url, options: [])
        } catch (let error) {
            print("\(error)")
            return nil
        }
        
        guard let dictionary = NSKeyedUnarchiver.unarchiveObject(with: data) as?  Dictionary<String, Any> else {
            return nil
        }
        
        return dictionary
    }
}

public class PersistentValue<T> {
    enum KeyValueError : Error {
        case unsupportedGenericType
    }

    private let itemType:KeyValueItem
    private let storage: PersistentValueStorage
    private let name:String
    
    enum KeyValueItem {
        case string
        case int
        case bool
        case data
    }
    
    public init(name: String, storage: PersistentValueStorage) throws {
        self.storage = storage
        self.name = name
                
        switch T.self {
        case is String.Type:
            itemType = .string
        case is Int.Type:
            itemType = .int
        case is Bool.Type:
            itemType = .bool
        case is Data.Type:
            itemType = .data
        default:
            throw KeyValueError.unsupportedGenericType
        }
    }
    
    public var value:T? {
        set {
            switch storage {
                case .userDefaults:
                    switch itemType {
                    case .string:
                        let key = DefaultsKey<String?>(name)
                        Defaults[key: key] = newValue as? String
                    case .int:
                        let key = DefaultsKey<Int?>(name)
                        Defaults[key: key] = newValue as? Int
                    case .bool:
                        let key = DefaultsKey<Bool?>(name)
                        Defaults[key: key] = newValue as? Bool
                    case .data:
                        let key = DefaultsKey<Data?>(name)
                        Defaults[key: key] = newValue as? Data
                    }
                
                    // 1/30/19; This is now deprecated. See Apple's docs and (https://medium.com/@hanru.yeh/nsuserdefaults-is-planned-to-deprecated-cc185e19e6f8) and (https://stackoverflow.com/questions/9647931/nsuserdefaults-synchronize-method)
                    // Plus, I was running into some apparent failures in my unit tests due to having this present.
                    // UserDefaults.standard.synchronize()
                
                case .file:
                    /* Need to handle two cases with file setter:
                        1) File doesn't yet exist-- first time a value is set.
                        2) File already exists.
                    */
                    
                    var dict: Dictionary<String, Any>!
                    
                    dict = PersistentValueFile.read()
                    if dict == nil {
                        dict = Dictionary<String, Any>()
                    }
                    
                    if let newValue = newValue {
                        dict[name] = newValue
                    }
                    else {
                        dict.removeValue(forKey: name)
                    }
                
                    if !PersistentValueFile.write(dictionary: dict) {
                        print("ERROR: Could not write dictionary to file: " + PersistentValueFile.backingFile)
                    }
                
                case .keyChain:
                    let keychain = PersistentValueKeychain.keychain
                    
                    guard let newValue = newValue else {
                        try? keychain.remove(name)
                        return
                    }

                    switch itemType {
                    case .string:
                        keychain[name] = newValue as? String

                    case .int:
                        var value = newValue
                        let data = Data(bytes: &value, count: MemoryLayout<Int>.size)
                        keychain[data: name] = data

                    case .bool:
                        var boolAsInt: Int = (newValue as! Bool) ? 1 : 0
                        let data = Data(bytes: &boolAsInt, count: MemoryLayout<Int>.size)
                        keychain[data: name] = data
                        
                    case .data:
                        keychain[data: name] = newValue as? Data
                    }
            }
        }
        
        get {
            switch storage {
                case .userDefaults:
                    switch itemType {
                    case .string:
                        let key = DefaultsKey<String?>(name)
                        return Defaults[key: key] as? T
                    case .int:
                        let key = DefaultsKey<Int?>(name)
                        return Defaults[key: key] as? T
                    case .bool:
                        let key = DefaultsKey<Bool?>(name)
                        return Defaults[key: key] as? T
                    case .data:
                        let key = DefaultsKey<Data?>(name)
                        return Defaults[key: key] as? T
                    }
                
                case .file:
                    guard let dict = PersistentValueFile.read() else {
                        print("ERROR: Could not read dictionary from file: " + PersistentValueFile.backingFile)

                        return nil
                    }
                    
                    // print("key: \(name): value: \(dict[name])")
                    
                    return dict[name] as? T
                
                case .keyChain:
                    let keychain = PersistentValueKeychain.keychain

                    switch itemType {
                    case .string:
                        return keychain[name] as? T
                        
                    case .int:
                        if let data = keychain[data: name] {
                            let result = getInt(fromData: data, start: 0)
                            return result as? T
                        }
                        else {
                            return nil
                        }
                        
                    case .bool:
                        if let data = keychain[data: name] {
                            let result = getInt(fromData: data, start: 0)
                            return (result == 1) as? T
                        }
                        else {
                            return nil
                        }
                        
                    case .data:
                        if let result = keychain[data: name] as? T {
                            return result
                        }
                        else {
                            return nil
                        }
                    } // end switch itemType
            } // end switch storage
        }
    }
    
    // From https://stackoverflow.com/questions/26227702/converting-nsdata-to-integer-in-swift
    private func getInt(fromData data: Data, start: Int) -> Int {
        let intBits = data.withUnsafeBytes({(bytePointer: UnsafePointer<UInt8>) -> Int in
            bytePointer.advanced(by: start).withMemoryRebound(to: Int.self, capacity: 4) { pointer in
                return pointer.pointee
            }
        })
        return Int(littleEndian: intBits)
    }
}

