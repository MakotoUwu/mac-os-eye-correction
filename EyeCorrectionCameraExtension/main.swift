//
//  main.swift
//  EyeCorrectionCameraExtension
//
//  Created by Oleksandr Tsepukh on 04/05/2025.
//

import Foundation
import CoreMediaIO

let providerSource = EyeCorrectionCameraExtensionProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
