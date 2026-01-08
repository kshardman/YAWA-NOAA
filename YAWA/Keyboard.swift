//
//  Keyboard.swift
//  iOSWeather
//
//  Created by Keith Sharman on 1/1/26.
//


import SwiftUI
import UIKit

extension View {
    func dismissKeyboard() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder),
            to: nil,
            from: nil,
            for: nil
        )
    }
}
