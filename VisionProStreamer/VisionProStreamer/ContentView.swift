//
//  ContentView.swift
//  VisionProStreamer
//
//  Created by Pushkar Khetrapal on 07/02/26.
//

import ARKit
import RealityKit
import SwiftUI
import Foundation
import simd
import Network
import VideoToolbox

import Foundation
import Network
import VideoToolbox
import CoreVideo
import CoreImage
import CoreImage.CIFilterBuiltins

import ARKit

import AVFoundation

import SwiftUI
import ARKit
import Vision
import AVFoundation

func transformToDict(_ matrix: simd_float4x4) -> [String: Float] {
    // Translation
    let x = matrix.columns.3.x
    let y = matrix.columns.3.y
    let z = matrix.columns.3.z

    // Rotation (extract Euler angles from rotation matrix part)
    let r11 = matrix.columns.0.x
    let r12 = matrix.columns.1.x
    let r13 = matrix.columns.2.x
    let r21 = matrix.columns.0.y
    let r22 = matrix.columns.1.y
    let r23 = matrix.columns.2.y
    let r31 = matrix.columns.0.z
    let r32 = matrix.columns.1.z
    let r33 = matrix.columns.2.z

    // Yaw (Z), Pitch (Y), Roll (X)
    let yaw = atan2(r21, r11)               // Z rotation
    let pitch = atan2(-r31, sqrt(r32*r32 + r33*r33)) // Y rotation
    let roll = atan2(r32, r33)              // X rotation

    return [
        "x": x,
        "y": y,
        "z": z,
        "roll": roll,
        "pitch": pitch,
        "yaw": yaw
    ]
}

func handAnchorToDict(_ handAnchor: HandAnchor) -> [String: Any] {
    var jointsArray: [[String: Any]] = []

    let jointTypes: [HandSkeleton.JointName] = [
        .wrist,
        .thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip,
        .indexFingerMetacarpal, .indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip,
        .middleFingerMetacarpal, .middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip,
        .ringFingerMetacarpal, .ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip,
        .littleFingerMetacarpal, .littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip,
    ]

    for jointType in jointTypes {
        if let joint = handAnchor.handSkeleton?.joint(jointType), joint.isTracked {
            jointsArray.append([
                "jointName": "\(jointType)",
                "pose": transformToDict(joint.anchorFromJointTransform)
            ])
        }
    }

    let handData: [String: Any] = [
        "hand": "\(handAnchor.chirality)", // "left" or "right"
        "handPose": transformToDict(handAnchor.originFromAnchorTransform),
        "joints": jointsArray
    ]

    return handData
}

let arKitSession = ARKitSession()
let worldTrackingProvider = WorldTrackingProvider()
let cameraFrameProvider = CameraFrameProvider()
let handTracking = HandTrackingProvider()
let sceneReconstruction = SceneReconstructionProvider()

//let udpSender = UDPSender(host: "10.82.3.162", port: 9999) // replace with your PC IP

struct ContentView: View {
    
    @State private var leftPixelBuffer: CVPixelBuffer?
    @State private var rightPixelBuffer: CVPixelBuffer?
    @State private var cameraImageLeft: Image?
    @State private var cameraImageRight: Image?
    @State private var isStreaming = true
    @State private var sendPoseData = false
    
    // Camera providers
    let formats = CameraVideoFormat.supportedVideoFormats(for: .main, cameraPositions: [.left, .right])
    
    // RTP Streamers
    let leftStreamer = RTPH264Streamer(host: "172.20.10.3", port: 5004)
    let rightStreamer = RTPH264Streamer(host: "172.20.10.3", port: 5006 ) // different port
    
    var body: some View {
        VStack(spacing: 12) {
            Text("Stereo Camera Feed")
                .font(.headline)
            
            HStack(spacing: 8) {
                if let cameraImageLeft {
                    cameraImageLeft
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text("No Left Image")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.35))
                }
                
                if let cameraImageRight {
                    cameraImageRight
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    Text("No Right Image")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.35))
                }
            }
            .cornerRadius(10)
            .padding(.bottom, 30)
            
            Spacer()
            
            HStack(spacing: 40) {
                Button(isStreaming ? "Stop Stream" : "Start Stream") {
                    Task {
                        isStreaming.toggle()
                        print("Streaming : ", isStreaming)
                    }
                }
                .padding()
                .background(isStreaming ? Color.red.opacity(0.3) : Color.blue.opacity(0.2))
                .cornerRadius(8)
                
                Button(sendPoseData ? "Stop Send Pose" : "Start Send Pose") {
                    Task {
                        sendPoseData.toggle()
                        print("sending pose data : ", sendPoseData)
                    }
                }
                .padding()
                .background(sendPoseData ? Color.red.opacity(0.3) : Color.blue.opacity(0.2))
                .cornerRadius(8)
            }
        }
        .padding()
        .task {
//            await openImmersiveSpace(id: "CameraSpace")
            let auth = await arKitSession.requestAuthorization(for: [.cameraAccess])
            print("Auth result:", auth)
            guard auth[.cameraAccess] == .allowed else {
                print("Camera access denied")
                return
            }
            try? await arKitSession.run([cameraFrameProvider, worldTrackingProvider, handTracking, sceneReconstruction])
            try? await Task.sleep(for: .milliseconds(300))
            Task.detached {
                await startCameraStream()
            }
            await processAllUpdates()
            
            print("calling send pose")
            
        }
    }
    // MARK: - Start streaming
    func startCameraStream() async {
        guard let vid_format = formats.first,
              let cameraFrameUpdates = cameraFrameProvider.cameraFrameUpdates(for: vid_format) else {
            print("Unable to acquire camera frame updates")
            return
        }
        
        print("Selected format:", vid_format)

        guard let cameraFrameUpdates =
                cameraFrameProvider.cameraFrameUpdates(for: vid_format) else {
            print("Unable to acquire camera frame updates for format:", vid_format)
            return
        }
        
        print("Using video format: \(vid_format)")
        
        for await cameraFrame in cameraFrameUpdates {
            guard let leftSample = cameraFrame.sample(for: .left),
                  let rightSample = cameraFrame.sample(for: .right) else {
                continue
            }
            
            leftPixelBuffer = leftSample.buffer.withUnsafeBuffer { $0 }
            rightPixelBuffer = rightSample.buffer.withUnsafeBuffer { $0 }
            
            // Local preview
            if let leftBuffer = leftPixelBuffer,
               let uiImage = UIImage(pixelBuffer: leftBuffer) {
                self.cameraImageLeft = Image(uiImage: uiImage)
            }
            if let rightBuffer = rightPixelBuffer,
               let uiImage = UIImage(pixelBuffer: rightBuffer) {
                self.cameraImageRight = Image(uiImage: uiImage)
            }
            
            let ts = leftSample.parameters.captureTimestamp
                        print(ts)
                        let deviceAnchor = worldTrackingProvider.queryDeviceAnchor(atTimestamp: ts)
                        print("Pose matrix:", deviceAnchor?.originFromAnchorTransform)
                        var collectedData: [String: Any] = [:]
            
    
            //            collectedData["timestamp"] = ts
            print(deviceAnchor?.originFromAnchorTransform)
            collectedData["devicePose"] = deviceAnchor?.originFromAnchorTransform
            collectedData["isTracked"] = deviceAnchor?.isTracked
            if let anchor = deviceAnchor {
                let json2 = transformToDict(anchor.originFromAnchorTransform)
                print(json2)
                
                collectedData["head_data"] = json2
//                udpSender.send(dataDict: collectedData)
//                print(collectedData)
            }
            
            // You can also append hand & mesh data here if you merge everything
            // For now, sending just device pose
            if isStreaming {
                print("Encode and send")
                if let leftBuffer = leftPixelBuffer {
                    leftStreamer.encodeAndSendH264Frame(pixelBuffer: leftBuffer)
                }else{
                    print("did not send left")
                }
                
                if let rightBuffer = rightPixelBuffer {
                    rightStreamer.encodeAndSendH264Frame(pixelBuffer: rightBuffer)
                }
                else{
                    print("did not send right")
                }
            }
            
            try? await Task.sleep(for: .milliseconds(1)) // ~30 fps pacing
        }
    }
    
    
    
    // MARK: - Send Pose
    func processAllUpdates() async {
        
        for await update in handTracking.anchorUpdates {
            let handDict = handAnchorToDict(update.anchor)
            if let data = try? JSONSerialization.data(withJSONObject: handDict, options: .prettyPrinted),
               let json = String(data: data, encoding: .utf8) {
                print(json) // or send via UDP
            }
//            udpSender.send(dataDict: handDict)
        }
    }
}

// MARK: - CVPixelBuffer → UIImage
extension UIImage {
    public convenience init?(pixelBuffer: CVPixelBuffer) {
        var cgImage: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cgImage)
        if let cgImage = cgImage {
            self.init(cgImage: cgImage)
        } else {
            return nil
        }
    }
}

#Preview(windowStyle: .automatic) {
    ContentView()
}
