//
//  JSONEncoderTests.swift
//  PMJSON
//
//  Created by Lily Ballard on 11/1/16.
//  Copyright © 2016 Postmates.
//
//  Licensed under the Apache License, Version 2.0 <LICENSE-APACHE or
//  http://www.apache.org/licenses/LICENSE-2.0> or the MIT license
//  <LICENSE-MIT or http://opensource.org/licenses/MIT>, at your
//  option. This file may not be copied, modified, or distributed
//  except according to those terms.
//

import PMJSON
import XCTest

import struct Foundation.Decimal

/// - Note: The encoder is primarily tested with round-trip tests in `JSONDecoderTests`.
public final class JSONEncoderTests: XCTestCase {
    public static let allLinuxTests = [
        ("testDecimalEncoding", testDecimalEncoding),
        ("testEncodeAsData", testEncodeAsData),
        ("testFoundationRoundTrip", testFoundationRoundTrip)
    ]
    
    func testDecimalEncoding() {
        XCTAssertEqual(JSON.encodeAsString(.decimal(42.714)), "42.714")
        XCTAssertEqual(JSON.encodeAsString([1, JSON(Decimal(string: "1.234567890123456789")!)]), "[1,1.234567890123456789]")
    }
    
    func testEncodeAsData() {
        // Because we hve the fancy buffering in encodeAsData, let's make sure we get the correct
        // results for a few different inputs
        func helper(_ input: JSON, file: StaticString = #file, line: UInt = #line) {
            let str = JSON.encodeAsString(input)
            let data = JSON.encodeAsData(input)
            XCTAssertEqual(str.data(using: .utf8)!, data, file: file, line: line)
        }
        
        // Whole thing is below max chunk size
        helper(["foo": "bar"])
        // Include a single chunk larger than the max chunk size
        helper(["long string": .string(String(repeating: "A", count: 33 * 1024))])
        // Whole JSON string is multiple chunks
        helper(["array": .array(JSONArray(repeating: "hello", count: 32 * 1024))])
    }

    func testFoundationRoundTrip() {
        var foundationObject = [String:Any]()
        foundationObject["values"] = ["size": 0,
                                      "volume": 1,
                                      "circumference": 0,
                                      "isFull": false,
                                      "isEmpty": true]

        //Encode
        var jsonData: Data? = nil
        var jsonDataRef: Data? = nil
        do {
            let interJSONRep = try JSON(foundation: foundationObject)
            jsonData = JSON.encodeAsData(interJSONRep)
        } catch {
            print("Couldn't serialize object due to error: \(error). (Object: \(String(describing: foundationObject)))")
            XCTFail()
        }

        if JSONSerialization.isValidJSONObject(foundationObject) {
            do {
                jsonDataRef = try JSONSerialization.data(withJSONObject: foundationObject)
            } catch {
                print("Couldn't serialize object due to error: \(error). (Object: \(String(describing: foundationObject)))")
                XCTFail()
            }
        }

        if jsonData != jsonDataRef {
            var newJSONDataString = "null"
            if let jsonDataUW = jsonData {
                newJSONDataString = String(data: jsonDataUW, encoding: .utf8) ?? "Bad UTF8 Data"
            }
            var refJSONDataString = "null"
            if let refJSONDataUW = jsonDataRef {
                refJSONDataString = String(data: refJSONDataUW, encoding: .utf8) ?? "Bad UTF8 Data"
            }
            print("New JSON Data:\n\(newJSONDataString)\n\nReference JSON Data:\n\(refJSONDataString))")
            XCTFail()
        }
        else {
            var newJSONDataString = "null"
            if let jsonDataUW = jsonData {
                newJSONDataString = String(data: jsonDataUW, encoding: .utf8) ?? "Bad UTF8 Data"
            }
            print("Encoded foundation object: '\(newJSONDataString)'")
        }

        XCTAssertNotNil(jsonData)

        if let jsonDataUW = jsonData {
            //Decode
            var jsonDict: [String: Any]? = nil
            var jsonDictRef: [String: Any]? = nil
            do {
                let interJSONRep = try JSON.decode(jsonDataUW)
                jsonDict = interJSONRep.foundation as? [String:Any]
                jsonDictRef = try JSONSerialization.jsonObject(with: jsonDataUW, options: .allowFragments) as? [String:Any]
            } catch {
                print("Couldn't deserialize JSON from data due to error: \(error). (Data: \(jsonDataUW))")
            }

            let jsonDictString = String(describing: jsonDict)
            let jsonDictRefString = String(describing: jsonDictRef)

            if jsonDictString != jsonDictRefString {
                print("New Dict Result:\n\(jsonDictString)\n\nReference Dict Result:\n\(jsonDictRefString)")
                XCTFail()
            }
            else {
                let jsonDictString = String(describing: jsonDict)
                print("New Dict Result:\n\(jsonDictString)")
            }
        }


    }
}

public final class JSONEncoderBenchmarks: XCTestCase {
    public static let allLinuxTests = [
        ("testEncodePerformance", testEncodePerformance),
        ("testEncodeAsDataPerformance", testEncodeAsDataPerformance),
        ("testEncodeAsStringConvertedToDataPerformance", testEncodeAsStringConvertedToDataPerformance),
        ("testEncodePrettyPerformance", testEncodePrettyPerformance),
        ("testEncodePrettyAsDataPerformance", testEncodePrettyAsDataPerformance)
    ]
    
    func testEncodePerformance() throws {
        let json = try JSON.decode(bigJson)
        measure {
            for _ in 0..<10 {
                _ = JSON.encodeAsString(json)
            }
        }
    }
    
    func testEncodeAsDataPerformance() throws {
        let json = try JSON.decode(bigJson)
        measure {
            for _ in 0..<10 {
                _ = JSON.encodeAsData(json)
            }
        }
    }
    
    func testEncodeAsStringConvertedToDataPerformance() throws {
        let json = try JSON.decode(bigJson)
        measure {
            for _ in 0..<10 {
                _ = JSON.encodeAsString(json).data(using: .utf8)
            }
        }

    }
    
    #if os(iOS) || os(OSX) || os(watchOS) || os(tvOS)
    func testEncodeCocoaPerformance() throws {
        let json = try JSON.decode(bigJson).ns
        measure {
            for _ in 0..<10 {
                do {
                    _ = try JSONSerialization.data(withJSONObject: json)
                } catch {
                    XCTFail("error encoding json: \(error)")
                }
            }
        }
    }
    #endif
    
    func testEncodePrettyPerformance() throws {
        let json = try JSON.decode(bigJson)
        measure {
            for _ in 0..<10 {
                _ = JSON.encodeAsString(json, options: [.pretty])
            }
        }
    }
    
    func testEncodePrettyAsDataPerformance() throws {
        let json = try JSON.decode(bigJson)
        measure {
            for _ in 0..<10 {
                _ = JSON.encodeAsData(json, options: [.pretty])
            }
        }
    }
    
    #if os(iOS) || os(OSX) || os(watchOS) || os(tvOS)
    func testEncodePrettyCocoaPerformance() throws {
        let json = try JSON.decode(bigJson).ns
        measure {
            for _ in 0..<10 {
                do {
                    _ = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted])
                } catch {
                    XCTFail("error encoding json: \(error)")
                }
            }
        }
    }
    #endif
}
