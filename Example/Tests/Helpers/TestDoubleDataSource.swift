//
//  TestDoubleDataSource.swift
//  BitmovinConvivaAnalytics_Tests
//
//  Created by Bitmovin on 11.10.18.
//  Copyright (c) 2018 Bitmovin. All rights reserved.
//

import Foundation

protocol TestDoubleDataSource {
    var mocks: [String: Any] { get }
    func spy(functionName: String, args: [String: String]?)
}

extension TestDoubleDataSource {
    var mocks: [String: Any] {
        return TestHelper.shared.mockTracker.mocks
    }

    func spy(functionName: String, args: [String: String]? = nil) {
        TestHelper.shared.spy(functionName: functionName, args: args)
    }
}
