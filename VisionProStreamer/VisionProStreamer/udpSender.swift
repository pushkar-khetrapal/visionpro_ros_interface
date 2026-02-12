//
//  udpSender.swift
//  VisionProStreamer
//
//  Created by Pushkar Khetrapal on 09/02/26.

import VideoToolbox
import Foundation
import Network
import Darwin

//class UDPSender {
//    let connection: NWConnection
//
//    init(host: String, port: UInt16) {
//        connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp)
//        connection.start(queue: .global())
//    }
//
//    func send(dataDict: [String: Any]) {
//        do {
//            let jsonData = try JSONSerialization.data(withJSONObject: dataDict, options: [])
//            connection.send(content: jsonData, completion: .contentProcessed({ error in
//                if let error = error {
//                    print("UDP send error:", error)
//                }
//            }))
//        } catch {
//            print("JSON encode error:", error)
//        }
//    }
//}


class RTPH264Streamer {
   private var connection: NWConnection?
   private var pathMonitor: NWPathMonitor?
   private let queue = DispatchQueue(label: "RTPH264Streamer", qos: .userInitiated)
   private var compressionSession: VTCompressionSession?
   private var host: String
   private var port: UInt16
   private var sequenceNumber: UInt16 = 0
   private var ssrc: UInt32 = 0x12345678 // Synchronization Source identifier
   private var rtpTimestamp: UInt32 = 0

   init(host: String, port: UInt16) {
       self.host = host
       self.port = port
       print("🔍 Connecting to: \(host):\(port)")
       self.triggerLocalNetworkPermission()
       self.startNetworkMonitoring()
       self.setupConnection()
       self.setupCompressionSession()
   }
    
    private func triggerLocalNetworkPermission() {
        let params = NWParameters.udp
        let listener = try? NWListener(using: params, on: .any)
        listener?.stateUpdateHandler = { state in
            print("Listener state: \(state)")
        }
        listener?.newConnectionHandler = { _ in }
        listener?.start(queue: queue)
        
        // Cancel after 1 second - we just needed to trigger the prompt
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            listener?.cancel()
        }
    }

    private func startNetworkMonitoring() {
            pathMonitor = NWPathMonitor()
            pathMonitor?.pathUpdateHandler = { [weak self] path in
                print("Network path status: \(path.status)")
                if path.status == .satisfied {
                    print("✅ Network is available")
                    print("Available interfaces: \(path.availableInterfaces)")
                    self?.setupConnection()
                } else {
                    print("❌ Network not available")
                }
            }
            pathMonitor?.start(queue: queue)
        }
   private func setupConnection() {
       let nwEndpoint = NWEndpoint.Host(self.host)
       let nwPort = NWEndpoint.Port(rawValue: self.port)!
       self.connection = NWConnection(host: nwEndpoint, port: nwPort, using: .udp)
       self.connection?.stateUpdateHandler = { state in
           print("UDP connection state: \(state)")
       }
       self.connection?.start(queue: self.queue)
   }
    
   // Additional recommendations for compression session setup
   private func setupCompressionSession() {
       let width = 1920
       let height = 1080
       var status = VTCompressionSessionCreate(
           allocator: kCFAllocatorDefault,
           width: Int32(width),
           height: Int32(height),
           codecType: kCMVideoCodecType_H264,
           encoderSpecification: nil,
           imageBufferAttributes: nil,
           compressedDataAllocator: nil,
           outputCallback: didCompressFrame,
           refcon: Unmanaged.passUnretained(self).toOpaque(),
           compressionSessionOut: &compressionSession
       )

       guard status == noErr, let session = compressionSession else {
           print("Error creating compression session: \(status)")
           return
       }

       // IMPROVED: Better properties for streaming
       VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_H264_Baseline_AutoLevel)
       VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
       VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)

       VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 500000 as CFNumber)
       VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [500000, 1] as CFArray)

       VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: 30 as CFNumber)
       VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.55 as CFNumber)

       VTCompressionSessionPrepareToEncodeFrames(session)
       print("Compression session setup complete.")
   }


   func encodeAndSendH264Frame(pixelBuffer: CVPixelBuffer) {
       guard let session = compressionSession else { return }

       // Increment timestamp for each new frame (90000 Hz clock for RTP video)
       rtpTimestamp += UInt32(90000 / 30) // Assuming 30 fps

       VTCompressionSessionEncodeFrame(
           session,
           imageBuffer: pixelBuffer,
           presentationTimeStamp: CMTime(value: Int64(rtpTimestamp), timescale: 90000),
           duration: CMTime.invalid,
           frameProperties: nil,
           sourceFrameRefcon: Unmanaged.passUnretained(self).toOpaque(), infoFlagsOut: nil
       )
   }

   // --- Helpers: convert CMTime -> 90kHz RTP timestamp
   private func rtpTimestampFromCMSampleBuffer(_ sampleBuffer: CMSampleBuffer) -> UInt32 {
       let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
       // convert to 90kHz clock: timestamp = seconds * 90000
       let seconds = CMTimeGetSeconds(pts)
       if seconds.isFinite {
           let ts = UInt64(seconds * 90000.0)
           return UInt32(truncatingIfNeeded: ts)
       } else {
           return self.rtpTimestamp // fallback (shouldn't normally happen)
       }
   }

   // --- Updated compression callback
   private let didCompressFrame: VTCompressionOutputCallback = {
       (refcon, sourceFrameRefcon, status, infoFlags, sampleBuffer) in

       guard status == noErr, let sampleBuffer = sampleBuffer else {
           print("Error compressing frame: \(status)")
           return
       }

       let streamer = Unmanaged<RTPH264Streamer>.fromOpaque(refcon!).takeUnretainedValue()

       // Use the sample buffer's PTS to derive RTP timestamp
       let timestamp = streamer.rtpTimestampFromCMSampleBuffer(sampleBuffer)

       // Attachments: NotSync == true means NOT sync (i.e., NOT a keyframe).
       let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]]
       let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool ?? false
       let isKeyFrame = (notSync == false) // invert NotSync

       if isKeyFrame {
           if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
               var spsSize: Int = 0
               var ppsSize: Int = 0
               var spsPointer: UnsafePointer<UInt8>?
               var ppsPointer: UnsafePointer<UInt8>?

               // Get SPS (index 0) and PPS (index 1)
               let _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                   formatDescription,
                   parameterSetIndex: 0,
                   parameterSetPointerOut: &spsPointer,
                   parameterSetSizeOut: &spsSize,
                   parameterSetCountOut: nil,
                   nalUnitHeaderLengthOut: nil
               )

               let _ = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                   formatDescription,
                   parameterSetIndex: 1,
                   parameterSetPointerOut: &ppsPointer,
                   parameterSetSizeOut: &ppsSize,
                   parameterSetCountOut: nil,
                   nalUnitHeaderLengthOut: nil
               )

               if let spsPtr = spsPointer, let ppsPtr = ppsPointer {
                   let sps = Data(bytes: spsPtr, count: spsSize)
                   let pps = Data(bytes: ppsPtr, count: ppsSize)
                   print("📤 Sending SPS (\(spsSize) bytes): \(sps.prefix(10).map { String(format: "%02X", $0) }.joined())")
                   print("📤 Sending PPS (\(ppsSize) bytes): \(pps.prefix(10).map { String(format: "%02X", $0) }.joined())")
                   streamer.sendNalu(data: sps, type: 7, timestamp: timestamp) // SPS type 7
                   streamer.sendNalu(data: pps, type: 8, timestamp: timestamp) // PPS type 8
               }
           }
       }

       // Get block buffer (this gives Annex B length-prefixed NALUs usually)
       guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

       var totalLength: Int = 0
       var dataPointerCChar: UnsafeMutablePointer<CChar>? = nil

       let status = CMBlockBufferGetDataPointer(
           dataBuffer,
           atOffset: 0,
           lengthAtOffsetOut: nil,
           totalLengthOut: &totalLength,
           dataPointerOut: &dataPointerCChar
       )

       guard status == kCMBlockBufferNoErr, let dataPointerCChar = dataPointerCChar else { return }

       // Cast to UInt8 pointer for safe byte work
       let dataPointer = UnsafeMutableRawPointer(dataPointerCChar).assumingMemoryBound(to: UInt8.self)

       var offset = 0
       while offset < totalLength {
           // Read 4-byte length
           var naluLengthBE: UInt32 = 0
           memcpy(&naluLengthBE, dataPointer.advanced(by: offset), 4)
           let naluLength = Int(CFSwapInt32BigToHost(naluLengthBE))
           offset += 4

           if offset + naluLength > totalLength { break }

           let naluData = Data(bytes: dataPointer.advanced(by: offset), count: naluLength)
           let headerByte = dataPointer.advanced(by: offset).pointee
           let naluType = Int(headerByte & 0x1F)

           streamer.sendNalu(data: naluData, type: naluType, timestamp: timestamp)

           offset += naluLength
       }
   }



   // --- Fixed sendNalu & sendRTPPacket
   private func sendNalu(data: Data, type: Int, timestamp: UInt32) {
       let mtu = 1400
       // data already contains the original NAL header as data[0]
       let headerByte = data[0]
       let nriAndF = headerByte & 0xE0 // F and NRI bits
       let naluPayload = data.advanced(by: 1) // payload without the NAL header

       // If small enough -> single RTP packet (whole NALU)
       if data.count <= mtu {
           // Single NALU RTP payload = whole NALU (header + payload)
           self.sendRTPPacket(payload: data, timestamp: timestamp, marker: true)
           return
       }

       // Fragmentation (FU-A). For FU-A we do not include the original NAL header in payload chunks.
       let maxChunkSize = mtu - 2 // 2 bytes for FU indicator + FU header
       var offset = 0
       let payloadBytes = [UInt8](naluPayload) // easier indexing
       let payloadSize = payloadBytes.count

       while offset < payloadSize {
           let chunkSize = min(maxChunkSize, payloadSize - offset)
           let isFirst = (offset == 0)
           let isLast = (offset + chunkSize) >= payloadSize

           // FU indicator: F(1) | NRI(2) | Type(5=28)
           let fuIndicator: UInt8 = (nriAndF) | 28

           // FU header: S | E | R | type(5)
           var fuHeader: UInt8 = headerByte & 0x1F // low 5 bits = original type
           if isFirst { fuHeader |= 0x80 } // set Start bit
           if isLast  { fuHeader |= 0x40 } // set End bit

           // chunk payload
           let chunk = Data(payloadBytes[offset ..< offset + chunkSize])
           let packetPayload = Data([fuIndicator, fuHeader]) + chunk

           self.sendRTPPacket(payload: packetPayload, timestamp: timestamp, marker: isLast)
           offset += chunkSize
       }
   }

   private func sendRTPPacket(payload: Data, timestamp: UInt32, marker: Bool) {
       var rtpHeader = Data(count: 12)
       rtpHeader[0] = 0x80 // v=2, no padding, no extension, cc=0

       let payloadType: UInt8 = 96
       rtpHeader[1] = (marker ? 0x80 : 0x00) | (payloadType & 0x7F)

       // sequence number (big-endian)
       var seqBE = sequenceNumber.bigEndian
       rtpHeader.withUnsafeMutableBytes { bytesPtr in
           bytesPtr.baseAddress!.advanced(by: 2).copyMemory(from: &seqBE, byteCount: 2)
       }

       // timestamp (big-endian)
       var tsBE = timestamp.bigEndian
       rtpHeader.withUnsafeMutableBytes { bytesPtr in
           bytesPtr.baseAddress!.advanced(by: 4).copyMemory(from: &tsBE, byteCount: 4)
       }

       // ssrc (big-endian)
       var ssrcBE = ssrc.bigEndian
       rtpHeader.withUnsafeMutableBytes { bytesPtr in
           bytesPtr.baseAddress!.advanced(by: 8).copyMemory(from: &ssrcBE, byteCount: 4)
       }

       let packet = rtpHeader + payload
       if sequenceNumber % 30 == 0 { // Log every 30 packets
               print("📤 Sent packet #\(sequenceNumber), size: \(packet.count), marker: \(marker)")
           }
       
       
           
       self.connection?.send(content: packet, completion: .contentProcessed { error in
           if let error = error {
               print("Send error: \(error)")
           }
       })

       self.sequenceNumber &+= 1
   }
}
