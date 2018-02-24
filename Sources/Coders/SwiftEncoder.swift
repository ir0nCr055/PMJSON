//
//  SwiftEncoder.swift
//  PMJSON
//
//  Created by Kevin Ballard on 2/16/18.
//  Copyright © 2018 Kevin Ballard.
//
//  Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
//  http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
//  <LICENSE-MIT or http://opensource.org/licenses/MIT>, at your
//  option. This file may not be copied, modified, or distributed
//  except according to those terms.
//

import Foundation

// There are two reasonable approaches to encoding here that are compatible with the fact that
// encoders aren't strictly scoped-based (because of nested keyed encoders, and super encoders, and
// the fact that you can ask for multiple container encoders from a single Encoder).
//
// The first is to build up a parallel JSON-like enum that boxes up objets/arrays so they can be
// shared with the containers. This approach is relatively simple, but the downside is if we want to
// create a `JSON` we need to deep-copy the whole thing (though if we write a streaming encoder we
// can serialize to `String`/`Data` without the deep copy).
//
// The second approach is to have the encoder hold an enum that contains either a `JSON` primitive
// or a boxed object/array, and have it write this value into its parent when it deinits. Because
// each container holds onto its parent, we ensure we've always written any nested values before we
// try to write our own value to our parent. The upside is we don't build up a parallel JSON
// structure, so we end up with a JSON without deep-copying. The downside here is this is a fair
// amount more complicated, and there's a lot of edge cases involved that need to be handled
// correctly, including some that I don't believe can be handled correctly, such as creating a
// nested container, writing some values to it, creating a second nested container for the same key,
// writing the same nested keys to that, dropping that container, then dropping the first container.
// The values from the first container will overwrite the ones from the second, even though that's
// not the order we wrote them in.
//
// We're going to go with approach #1 because of the edge cases in #2.

private enum EncodedJSON {
    /// An unboxed JSON value.
    ///
    /// This should always contain a primitive, with the sole exception of when the encoder is asked
    /// to encode a `JSON` directly, which it will store unboxed. If we then ask for a nested
    /// container for the same key, and the previously-stored unboxed `JSON` is an object/array, we
    /// will box it at that point.
    case unboxed(JSON)
    case object(BoxedObject)
    case array(BoxedArray)
    /// A special-case for super encoders. We need to box a value but we don't know what the type of
    /// the value is yet. If the wrapped value is `nil` when we go to unbox this, we'll just assume
    /// an empty object.
    ///
    /// - Requires: This case should never contain `Box(.super(…))`.
    case `super`(Box<EncodedJSON?>)
    
    typealias BoxedObject = Box<[String: EncodedJSON]>
    typealias BoxedArray = Box<[EncodedJSON]>
    
    class Box<Value> {
        var value: Value
        
        init(_ value: Value) {
            self.value = value
        }
    }
    
    var isObject: Bool {
        switch self {
        case .unboxed(let json): return json.isObject
        case .object: return true
        case .array: return false
        case .super(let box): return box.value?.isObject ?? false
        }
    }
    
    var isArray: Bool {
        switch self {
        case .unboxed(let json): return json.isArray
        case .object: return false
        case .array: return true
        case .super(let box): return box.value?.isArray ?? false
        }
    }
    
    func unbox() -> JSON {
        switch self {
        case .unboxed(let value): return value
        case .object(let box):
            return .object(JSONObject(dict: box.value.mapValues({ $0.unbox() })))
        case .array(let box):
            return .array(JSONArray(box.value.map({ $0.unbox() })))
        case .super(let box):
            return box.value?.unbox() ?? .object(JSONObject())
        }
    }
    
    /// Extracts the boxed object from the given json.
    ///
    /// If the json contains `.unboxed(.object)`, the object is boxed first and stored back in the json.
    /// If the json contains `nil`, it's initialized to an empty object.
    static func boxObject(json: inout EncodedJSON?) -> BoxedObject? {
        switch json {
        case nil:
            let box = BoxedObject([:])
            json = .object(box)
            return box
        case .unboxed(.object(let object))?:
            let box = BoxedObject(object.dictionary.mapValues(EncodedJSON.init(boxing:)))
            json = .object(box)
            return box
        case .unboxed?:
            return nil
        case .object(let box)?:
            return box
        case .array?:
            return nil
        case .super(let box)?:
            return boxObject(json: &box.value)
        }
    }
    
    /// Extracts the boxed array from the given json.
    ///
    /// If the json contains `.unboxed(.array)`, the array is boxed first and stored back in the json.
    /// If the json contains `nil`, it's initialized to an empty array.
    static func boxArray(json: inout EncodedJSON?) -> BoxedArray? {
        switch json {
        case nil:
            let box = BoxedArray([])
            json = .array(box)
            return box
        case .unboxed(.array(let array))?:
            let box = BoxedArray(array.map(EncodedJSON.init(boxing:)))
            json = .array(box)
            return box
        case .unboxed?, .object?:
            return nil
        case .array(let box)?:
            return box
        case .super(let box)?:
            return boxArray(json: &box.value)
        }
    }
    
    init(boxing json: JSON) {
        switch json {
        case .object(let object): self = .object(Box(object.dictionary.mapValues(EncodedJSON.init(boxing:))))
        case .array(let array): self = .array(Box(array.map(EncodedJSON.init(boxing:))))
        default: self = .unboxed(json)
        }
    }
}

extension JSON {
    /// An object that encodes instances of data types that conform to `Encodable` to JSON streams.
    public struct Encoder {
        /// A dictionary you use to customize the encoding process by providing contextual information.
        public var userInfo: [CodingUserInfoKey: Any] = [:]
        
        /// Creates a new, reusable JSON encoder.
        public init() {}
        
        /// Returns a JSON-encoded representation of the value you supply.
        ///
        /// - Parameter value: The value to encode.
        /// - Returns: Data containing the JSON encoding of the value.
        /// - Throws: Any error thrown by a value's `encode(to:)` method.
        public func encodeAsData<T: Encodable>(_ value: T, options: JSONEncoderOptions = []) throws -> Data {
            return try JSON.encodeAsData(encodeAsJSON(value), options: options)
        }
        
        /// Returns a JSON-encoded representation of the value you supply.
        ///
        /// - Parameter value: The value to encode.
        /// - Returns: A string containing the JSON encoding of the value.
        /// - Throws: Any error thrown by a value's `encode(to:)` method.
        public func encodeAsString<T: Encodable>(_ value: T, options: JSONEncoderOptions = []) throws -> String {
            return try JSON.encodeAsString(encodeAsJSON(value), options: options)
        }
        
        /// Returns a JSON-encoded representation of the value you supply.
        ///
        /// - Parameter value: The value to encode.
        /// - Returns: The JSON encoding of the value.
        /// - Throws: Any error thrown by a value's `encode(to:)` method, or
        ///   `EncodingError.invalidValue` if the value doesn't encode anything.
        public func encodeAsJSON<T: Encodable>(_ value: T) throws -> JSON {
            let data = EncoderData()
            data.userInfo = userInfo
            let encoder = _JSONEncoder(data: data)
            try value.encode(to: encoder)
            guard let json = encoder.json else {
                throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Top-level \(type(of: value)) did not encode any values."))
            }
            return json.unbox()
        }
        
        @available(*, unavailable, renamed: "encodeAsData(_:)")
        public func encode<T: Encodable>(_ value: T) throws -> Data {
            return try encodeAsData(value)
        }
    }
}

private class EncoderData {
    var codingPath: [CodingKey] = []
    var userInfo: [CodingUserInfoKey: Any] = [:]
    
    func copy() -> EncoderData {
        let result = EncoderData()
        result.codingPath = codingPath
        result.userInfo = userInfo
        return result
    }
}

private class _JSONEncoder: Encoder {
    init(data: EncoderData, json: EncodedJSON? = nil) {
        _data = data
        value = json.map(Value.json)
    }
    
    init(data: EncoderData, box: EncodedJSON.Box<EncodedJSON?>) {
        _data = data
        value = .box(box)
    }
    
    private let _data: EncoderData
    private var value: Value?
    
    private enum Value {
        case json(EncodedJSON)
        case box(EncodedJSON.Box<EncodedJSON?>)
        
        var isEmpty: Bool {
            switch self {
            case .json(.super(let box)): return box.value == nil
            case .json: return false
            case .box(let box): return box.value == nil
            }
        }
    }
    
    var json: EncodedJSON? {
        get {
            switch value {
            case .json(let json)?: return json
            case .box(let box)?: return box.value
            case nil: return nil
            }
        }
        set {
            switch value {
            case nil, .json?: value = newValue.map(Value.json)
            case .box(let box)?: box.value = newValue
            }
        }
    }
    
    var codingPath: [CodingKey] {
        return _data.codingPath
    }
    
    var userInfo: [CodingUserInfoKey: Any] {
        return _data.userInfo
    }
    
    func container<Key>(keyedBy type: Key.Type) -> KeyedEncodingContainer<Key> where Key : CodingKey {
        let box_: EncodedJSON.BoxedObject?
        switch value {
        case .json(let json_)?:
            var json: EncodedJSON? = json_
            box_ = EncodedJSON.boxObject(json: &json)
            if box_ != nil, let json = json {
                value = .json(json)
            }
        case .box(let box)?:
            box_ = EncodedJSON.boxObject(json: &box.value)
        case nil:
            let box = EncodedJSON.BoxedObject([:])
            value = .json(.object(box))
            box_ = box
        }
        guard let box = box_ else {
            fatalError("Attempted to create a keyed encoding container when existing encoded value is not a JSON object.")
        }
        
        return KeyedEncodingContainer(_JSONKeyedEncoder<Key>(data: _data, box: box))
    }
    
    func unkeyedContainer() -> UnkeyedEncodingContainer {
        let box_: EncodedJSON.BoxedArray?
        switch value {
        case .json(let json_)?:
            var json: EncodedJSON? = json_
            box_ = EncodedJSON.boxArray(json: &json)
            if box_ != nil, let json = json {
                value = .json(json)
            }
        case .box(let box)?:
            box_ = EncodedJSON.boxArray(json: &box.value)
        case nil:
            let box = EncodedJSON.BoxedArray([])
            value = .json(.array(box))
            box_ = box
        }
        guard let box = box_ else {
            fatalError("Attempted to create an unkeyed encoding container when existing encoded value is not a JSON array.")
        }
        
        return _JSONUnkeyedEncoder(data: _data, box: box)
    }
    
    func singleValueContainer() -> SingleValueEncodingContainer {
        return self
    }
}

// MARK: -

extension _JSONEncoder: SingleValueEncodingContainer {
    private func assertCanWriteValue() {
        precondition(value?.isEmpty ?? true, "Attempted to encode value through single value container when previous value already encoded.")
    }
    
    func encodeNil() throws {
        assertCanWriteValue()
        json = .unboxed(.null)
    }
    
    func encode(_ value: Bool) throws {
        assertCanWriteValue()
        json = .unboxed(.bool(value))
    }
    
    func encode(_ value: Int) throws {
        assertCanWriteValue()
        json = .unboxed(.int64(Int64(value)))
    }
    
    func encode(_ value: Int8) throws {
        assertCanWriteValue()
        json = .unboxed(.int64(Int64(value)))
    }
    
    func encode(_ value: Int16) throws {
        assertCanWriteValue()
        json = .unboxed(.int64(Int64(value)))
    }
    
    func encode(_ value: Int32) throws {
        assertCanWriteValue()
        json = .unboxed(.int64(Int64(value)))
    }
    
    func encode(_ value: Int64) throws {
        assertCanWriteValue()
        json = .unboxed(.int64(value))
    }
    
    func encode(_ value: UInt) throws {
        assertCanWriteValue()
        guard let intValue = Int64(exactly: value) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "Encoded value is out of range for JSON integer."))
        }
        json = .unboxed(.int64(intValue))
    }
    
    func encode(_ value: UInt8) throws {
        assertCanWriteValue()
        json = .unboxed(.int64(Int64(value)))
    }
    
    func encode(_ value: UInt16) throws {
        assertCanWriteValue()
        json = .unboxed(.int64(Int64(value)))
    }
    
    func encode(_ value: UInt32) throws {
        assertCanWriteValue()
        json = .unboxed(.int64(Int64(value)))
    }
    
    func encode(_ value: UInt64) throws {
        assertCanWriteValue()
        guard let intValue = Int64(exactly: value) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "Encoded value is out of range for JSON integer."))
        }
        json = .unboxed(.int64(intValue))
    }
    
    func encode(_ value: Float) throws {
        assertCanWriteValue()
        json = .unboxed(.double(Double(value)))
    }
    
    func encode(_ value: Double) throws {
        assertCanWriteValue()
        json = .unboxed(.double(value))
    }
    
    func encode(_ value: String) throws {
        assertCanWriteValue()
        json = .unboxed(.string(value))
    }
    
    func encode<T>(_ value: T) throws where T : Encodable {
        switch value {
        case let json as JSON:
            self.json = .unboxed(json)
        case let decimal as Decimal:
            json = .unboxed(.decimal(decimal))
        default:
            try value.encode(to: self)
        }
    }
}

private class _JSONUnkeyedEncoder: UnkeyedEncodingContainer {
    init(data: EncoderData, box: EncodedJSON.BoxedArray) {
        _data = data
        self.box = box
    }

    private let _data: EncoderData
    private let box: EncodedJSON.BoxedArray
    
    var codingPath: [CodingKey] {
        return _data.codingPath
    }
    
    var count: Int {
        return box.value.count
    }
    
    private func append(unboxed json: JSON) {
        box.value.append(.unboxed(json))
    }
    
    func encodeNil() throws {
        append(unboxed: .null)
    }
    
    func encode(_ value: Bool) throws {
        append(unboxed: .bool(value))
    }
    
    func encode(_ value: Int8) throws {
        append(unboxed: .int64(Int64(value)))
    }
    
    func encode(_ value: Int16) throws {
        append(unboxed: .int64(Int64(value)))
    }
    
    func encode(_ value: Int32) throws {
        append(unboxed: .int64(Int64(value)))
    }
    
    func encode(_ value: Int64) throws {
        append(unboxed: .int64(value))
    }
    
    func encode(_ value: Int) throws {
        append(unboxed: .int64(Int64(value)))
    }
    
    func encode(_ value: UInt8) throws {
        append(unboxed: .int64(Int64(value)))
    }
    
    func encode(_ value: UInt16) throws {
        append(unboxed: .int64(Int64(value)))
    }
    
    func encode(_ value: UInt32) throws {
        append(unboxed: .int64(Int64(value)))
    }
    
    func encode(_ value: UInt64) throws {
        guard let intValue = Int64(exactly: value) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath + [JSONKey.int(count)], debugDescription: "Encoded value is out of range for JSON integer."))
        }
        append(unboxed: .int64(intValue))
    }
    
    func encode(_ value: UInt) throws {
        guard let intValue = Int64(exactly: value) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath + [JSONKey.int(count)], debugDescription: "Encoded value is out of range for JSON integer."))
        }
        append(unboxed: .int64(intValue))
    }
    
    func encode(_ value: Float) throws {
        append(unboxed: .double(Double(value)))
    }
    
    func encode(_ value: Double) throws {
        append(unboxed: .double(value))
    }
    
    func encode(_ value: String) throws {
        append(unboxed: .string(value))
    }
    
    func encode<T>(_ value: T) throws where T : Encodable {
        switch value {
        case let json as JSON:
            append(unboxed: json)
        case let decimal as Decimal:
            append(unboxed: .decimal(decimal))
        default:
            _data.codingPath.append(JSONKey.int(count))
            defer { _data.codingPath.removeLast() }
            let encoder = _JSONEncoder(data: _data)
            try value.encode(to: encoder)
            guard let json = encoder.json else {
                throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "\(type(of: value)) did not encode any values."))
            }
            box.value.append(json)
        }
    }
    
    func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type) -> KeyedEncodingContainer<NestedKey> where NestedKey : CodingKey {
        let data = _data.copy()
        data.codingPath.append(JSONKey.int(count))
        let box = EncodedJSON.BoxedObject([:])
        self.box.value.append(.object(box))
        return KeyedEncodingContainer(_JSONKeyedEncoder<NestedKey>(data: data, box: box))
    }
    
    func nestedUnkeyedContainer() -> UnkeyedEncodingContainer {
        let data = _data.copy()
        data.codingPath.append(JSONKey.int(count))
        let box = EncodedJSON.BoxedArray([])
        self.box.value.append(.array(box))
        return _JSONUnkeyedEncoder(data: data, box: box)
    }
    
    func superEncoder() -> Encoder {
        let data = _data.copy()
        data.codingPath.append(JSONKey.int(count))
        let box: EncodedJSON.Box<EncodedJSON?> = EncodedJSON.Box(nil)
        self.box.value.append(.super(box))
        return _JSONEncoder(data: data, box: box)
    }
}

private class _JSONKeyedEncoder<K: CodingKey>: KeyedEncodingContainerProtocol {
    typealias Key = K
    
    init(data: EncoderData, box: EncodedJSON.BoxedObject) {
        _data = data
        self.box = box
    }
    
    private let _data: EncoderData
    private let box: EncodedJSON.BoxedObject
    
    var codingPath: [CodingKey] {
        return _data.codingPath
    }
    
    private func store(unboxed json: JSON, forKey key: K) {
        box.value[key.stringValue] = .unboxed(json)
    }
    
    func encodeNil(forKey key: K) throws {
        store(unboxed: .null, forKey: key)
    }
    
    func encode(_ value: Bool, forKey key: K) throws {
        store(unboxed: .bool(value), forKey: key)
    }
    
    func encode(_ value: Int, forKey key: K) throws {
        store(unboxed: .int64(Int64(value)), forKey: key)
    }
    
    func encode(_ value: Int8, forKey key: K) throws {
        store(unboxed: .int64(Int64(value)), forKey: key)
    }
    
    func encode(_ value: Int16, forKey key: K) throws {
        store(unboxed: .int64(Int64(value)), forKey: key)
    }
    
    func encode(_ value: Int32, forKey key: K) throws {
        store(unboxed: .int64(Int64(value)), forKey: key)
    }
    
    func encode(_ value: Int64, forKey key: K) throws {
        store(unboxed: .int64(value), forKey: key)
    }
    
    func encode(_ value: UInt8, forKey key: K) throws {
        store(unboxed: .int64(Int64(value)), forKey: key)
    }
    
    func encode(_ value: UInt16, forKey key: K) throws {
        store(unboxed: .int64(Int64(value)), forKey: key)
    }
    
    func encode(_ value: UInt32, forKey key: K) throws {
        store(unboxed: .int64(Int64(value)), forKey: key)
    }
    
    func encode(_ value: UInt64, forKey key: K) throws {
        guard let intValue = Int64(exactly: value) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath + [key], debugDescription: "Encoded value is out of range for JSON integer."))
        }
        store(unboxed: .int64(intValue), forKey: key)
    }
    
    func encode(_ value: UInt, forKey key: K) throws {
        guard let intValue = Int64(exactly: value) else {
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath + [key], debugDescription: "Encoded value is out of range for JSON integer."))
        }
        store(unboxed: .int64(intValue), forKey: key)
    }
    
    func encode(_ value: Float, forKey key: K) throws {
        store(unboxed: .double(Double(value)), forKey: key)
    }
    
    func encode(_ value: Double, forKey key: K) throws {
        store(unboxed: .double(value), forKey: key)
    }
    
    func encode(_ value: String, forKey key: K) throws {
        store(unboxed: .string(value), forKey: key)
    }
    
    func encode<T>(_ value: T, forKey key: K) throws where T : Encodable {
        switch value {
        case let json as JSON:
            store(unboxed: json, forKey: key)
        case let decimal as Decimal:
            store(unboxed: .decimal(decimal), forKey: key)
        default:
            _data.codingPath.append(key)
            defer { _data.codingPath.removeLast() }
            let encoder = _JSONEncoder(data: _data)
            try value.encode(to: encoder)
            guard let json = encoder.json else {
                throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: codingPath, debugDescription: "\(type(of: value)) did not encode any values."))
            }
            box.value[key.stringValue] = json
        }
    }
    
    func nestedContainer<NestedKey>(keyedBy keyType: NestedKey.Type, forKey key: K) -> KeyedEncodingContainer<NestedKey> where NestedKey : CodingKey {
        let data = _data.copy()
        data.codingPath.append(key)
        let box = EncodedJSON.BoxedObject([:])
        self.box.value[key.stringValue] = .object(box)
        return KeyedEncodingContainer(_JSONKeyedEncoder<NestedKey>(data: data, box: box))
    }
    
    func nestedUnkeyedContainer(forKey key: K) -> UnkeyedEncodingContainer {
        let data = _data.copy()
        data.codingPath.append(key)
        let box = EncodedJSON.BoxedArray([])
        self.box.value[key.stringValue] = .array(box)
        return _JSONUnkeyedEncoder(data: data, box: box)
    }
    
    func superEncoder() -> Encoder {
        return _superEncoder(forKey: JSONKey.super)
    }
    
    func superEncoder(forKey key: K) -> Encoder {
        return _superEncoder(forKey: key)
    }
    
    private func _superEncoder(forKey key: CodingKey) -> Encoder {
        let data = _data.copy()
        data.codingPath.append(key)
        let box: EncodedJSON.Box<EncodedJSON?> = EncodedJSON.Box(nil)
        self.box.value[key.stringValue] = .super(box)
        return _JSONEncoder(data: data, box: box)
    }
}