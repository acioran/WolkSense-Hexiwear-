//
//  Hexiwear application is used to pair with Hexiwear BLE devices
//  and send sensor readings to WolkSense sensor data cloud
//
//  Copyright (C) 2016 WolkAbout Technology s.r.o.
//
//  Hexiwear is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  Hexiwear is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//
//
//  TrackingAPI.swift
//

import Foundation

protocol MQTTAPIProtocol {
    func didPublishReadings()
}

class MQTTAPI {
    
    let clientId = "HexiweariOSClient"
    var mqttClient: CocoaMQTT!
    var mqttPayload: String = ""
    var serial: String = ""
    var mqttDelegate: MQTTAPIProtocol?
    
    let MQTThost = "wolksense.com"
    let MQTTport: UInt16 = 8883
    var MQTTQoS: CocoaMQTTQOS = .QOS0
    
    //MARK: - Properties
    lazy var mqttRequestQueue: NSOperationQueue = {
        var queue = NSOperationQueue()
        queue.name = "com.wolkabout.Hexiwear.mqttApiQueue"
        queue.maxConcurrentOperationCount = 1 // just one running request allowed
        return queue
    }() // used to start and cancel mqtt client
    
    private var subscribeTopic: String {
        get {
            return "config/\(serial)"
        }
    }
    
    private var publishTopic: String {
        get {
            return "sensors/\(serial)"
        }
    }
    
    let responseSemaphore: NSCondition = NSCondition()
    var responseReceived = false
    
    
    //MARK: - Methods
    init(delegate: MQTTAPIProtocol? = nil, QoS: CocoaMQTTQOS = .QOS0) {
        self.mqttDelegate = delegate
        self.MQTTQoS = QoS
        
        mqttClient = CocoaMQTT(clientId: clientId, host: MQTThost, port: MQTTport)
        if let mqtt = mqttClient {
            mqtt.keepAlive = 60
            mqtt.secureMQTT = true
            mqtt.delegate = self
        }
    }
    
    func setAuthorisationOptions(username: String, password: String) {
        guard mqttClient != nil else { return }
        
        mqttClient.username = username
        mqttClient.password = password
        print("MQTT -- user:\(username) pass:\(password)")
    }
    
    private func signalResponseReceived() {
        self.responseSemaphore.lock()
        self.responseReceived = true
        self.responseSemaphore.signal()
        self.responseSemaphore.unlock()
    }
    
    private func tryDisconnect() {
        if mqttClient != nil && mqttClient.connState == .CONNECTED {
            mqttClient.disconnect()
        }
    }
    
}

extension MQTTAPI: CocoaMQTTDelegate {
    func mqtt(mqtt: CocoaMQTT, didConnect host: String, port: Int) {
        print("MQTT -- didConnect \(host):\(port)")
    }
    
    func mqtt(mqtt: CocoaMQTT, didConnectAck ack: CocoaMQTTConnAck) {
        if ack == .ACCEPT {
            self.mqttClient.publish(self.publishTopic, withString: mqttPayload, qos: self.MQTTQoS, retain: false, dup: false)
            return
        }
        
    }
    
    func mqtt(mqtt: CocoaMQTT, didPublishMessage message: CocoaMQTTMessage, id: UInt16) {
        print("MQTT -- didPublishMessage with id: \(id) and message: \(message.string)")
        tryDisconnect()
    }
    
    func mqtt(mqtt: CocoaMQTT, didPublishAck id: UInt16) {
        print("MQTT -- didPublishAck with id: \(id)")
    }
    
    func mqtt(mqtt: CocoaMQTT, didReceiveMessage message: CocoaMQTTMessage, id: UInt16 ) {
        print("MQTT -- didReceivedMessage: \(message.string) with id \(id)")
    }
    
    func mqtt(mqtt: CocoaMQTT, didSubscribeTopic topic: String) {
        print("MQTT -- didSubscribeTopic to \(topic)")
    }
    
    func mqtt(mqtt: CocoaMQTT, didUnsubscribeTopic topic: String) {
        print("MQTT -- didUnsubscribeTopic to \(topic)")
    }
    
    func mqttDidPing(mqtt: CocoaMQTT) {
        print("MQTT -- didPing")
    }
    
    func mqttDidReceivePong(mqtt: CocoaMQTT) {
        print("MQTT -- didReceivePong")
    }
    
    func mqttDidDisconnect(mqtt: CocoaMQTT, withError err: NSError?) {
        if let error = err { print("MQTT -- didDisconnect with error: \(error)") }
        
        signalResponseReceived()
        mqttDelegate?.didPublishReadings()
        print("MQTT -- didDisconnect")
    }
    
}

extension MQTTAPI {
    
    func publishHexiwearReadings(readings: HexiwearReadings, forSerial: String) {
        guard mqttRequestQueue.operationCount == 0 else {
            print("MQTT -- DROPPED PUBLISH as ALREADY one is RUNNING!!!!!")
            return
        }
        
        guard let mqttPayload = readings.asMQTTMessage() else {
            print("MQTT -- no valid MQTT message from hexiwear readings")
            return
        }
        
        let publish = PublishReadings(trackingAPI: self, mqttPayload: mqttPayload, serial: forSerial)
        mqttRequestQueue.addOperation(publish)
    }
    
    class PublishReadings: NSOperation {
        private unowned let trackingAPI: MQTTAPI
        private let mqttPayload: String
        private let serial: String
        
        init (trackingAPI: MQTTAPI, mqttPayload: String, serial: String) {
            self.trackingAPI = trackingAPI
            self.mqttPayload = mqttPayload
            self.serial = serial
        }
        
        override func main() {
            if self.cancelled {
                print("MQTT -- Cancelled publish locations")
                return
            }
            
            // create new MQTT Connection
            trackingAPI.mqttPayload = mqttPayload
            trackingAPI.serial = serial
            trackingAPI.mqttClient.connect()
            
            self.trackingAPI.responseSemaphore.lock()
            while !self.trackingAPI.responseReceived {
                self.trackingAPI.responseSemaphore.wait()
            }
            self.trackingAPI.responseReceived = false
            self.trackingAPI.responseSemaphore.unlock()
        }
    }
}

