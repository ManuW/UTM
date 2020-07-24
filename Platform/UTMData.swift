//
// Copyright © 2020 osy. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//

import Foundation

enum Actions {
    case none
    case run
    case edit
    case clone
    case delete
    case share
}

struct AlertMessage: Identifiable {
    var message: String
    public var id: String {
        message
    }
    
    init(_ message: String) {
        self.message = message
    }
}

class UTMData: ObservableObject {
    
    @Published var requestedAction: Actions
    @Published var alertMessage: AlertMessage?
    @Published var busy: Bool
    @Published var selectedVM: UTMVirtualMachine?
    @Published private(set) var virtualMachines: [UTMVirtualMachine] {
        didSet {
            let defaults = UserDefaults.standard
            var paths = [String]()
            virtualMachines.forEach({ vm in
                if let path = vm.path {
                    paths.append(path.lastPathComponent)
                }
            })
            defaults.set(paths, forKey: "VMList")
        }
    }
    
    var documentsURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }
    
    init() {
        let defaults = UserDefaults.standard
        self.requestedAction = .none
        self.busy = false
        self.virtualMachines = []
        if let files = defaults.array(forKey: "VMList") as? [String] {
            for file in files {
                let url = documentsURL.appendingPathComponent(file, isDirectory: true)
                if let vm = UTMVirtualMachine(url: url) {
                    self.virtualMachines.append(vm)
                }
            }
        }
        self.selectedVM = nil
    }
    
    func refresh() {
        let fileManager = FileManager.default
        // remove stale vm
        var list = virtualMachines.filter { (vm: UTMVirtualMachine) in vm.path != nil && fileManager.fileExists(atPath: vm.path!.path) }
        do {
            let files = try fileManager.contentsOfDirectory(at: documentsURL, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
            let newFiles = files.filter { newFile in
                !virtualMachines.contains { existingVM in
                    existingVM.path == newFile
                }
            }
            for file in newFiles {
                guard try file.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false else {
                    continue
                }
                guard UTMVirtualMachine.isVirtualMachine(url: file) else {
                    continue
                }
                let vm = UTMVirtualMachine(url: file)
                if vm != nil {
                    list.insert(vm!, at: 0)
                } else {
                    logger.error("Failed to create object for \(file)")
                }
            }
        } catch {
            logger.error("\(error.localizedDescription)")
        }
        if virtualMachines != list {
            DispatchQueue.main.async {
                //self.objectWillChange.send()
                self.virtualMachines = list
            }
        }
    }
    
    func newDefaultVMName(base: String = "Virtual Machine") -> String {
        let nameForId = { (i: Int) in i <= 1 ? base : "\(base) \(i)" }
        for i in 1..<1000 {
            let name = nameForId(i)
            let file = UTMVirtualMachine.virtualMachinePath(name, inParentURL: documentsURL)
            if !FileManager.default.fileExists(atPath: file.path) {
                return name
            }
        }
        return ProcessInfo.processInfo.globallyUniqueString
    }
    
    func newDefaultDriveName(type: UTMDiskImageType, forConfig: UTMConfiguration) -> String {
        let nameForId = { (i: Int) in "\(type.description)-\(i).qcow2" }
        for i in 0..<1000 {
            let name = nameForId(i)
            let file = forConfig.imagesPath.appendingPathComponent(name)
            if !FileManager.default.fileExists(atPath: file.path) {
                return name
            }
        }
        return UUID().uuidString
    }
    
    func save(vm: UTMVirtualMachine) throws {
        do {
            try vm.saveUTM()
        } catch {
            // refresh the VM object as it is now stale
            refreshConfiguration(for: vm)
            throw error
        }
    }
    
    func create(config: UTMConfiguration) throws {
        let vm = UTMVirtualMachine(configuration: config, withDestinationURL: documentsURL)
        try save(vm: vm)
        refreshConfiguration(for: vm)
    }
    
    func move(fromOffsets: IndexSet, toOffset: Int) {
        DispatchQueue.main.async {
            self.virtualMachines.move(fromOffsets: fromOffsets, toOffset: toOffset)
        }
    }
    
    func remove(atOffsets: IndexSet) {
        // TODO: implement delete
        DispatchQueue.main.async {
            self.virtualMachines.remove(atOffsets: atOffsets)
        }
    }
    
    func importDrive(_ drive: URL, forConfig: UTMConfiguration, copy: Bool = false) throws {
        let fileManager = FileManager.default
        let name = drive.lastPathComponent
        let imagesPath = forConfig.imagesPath
        let dstPath = imagesPath.appendingPathComponent(name)
        if !fileManager.fileExists(atPath: imagesPath.path) {
            try fileManager.createDirectory(at: imagesPath, withIntermediateDirectories: false, attributes: nil)
        }
        if copy {
            try fileManager.copyItem(at: drive, to: dstPath)
        } else {
            try fileManager.moveItem(at: drive, to: dstPath)
        }
        DispatchQueue.main.async {
            forConfig.newDrive(name, type: .CD, interface: UTMConfiguration.defaultDriveInterface())
        }
    }
    
    func createDrive(_ drive: VMDriveImage, forConfig: UTMConfiguration) throws {
        var name: String = ""
        if !drive.removable {
            guard drive.size > 0 else {
                throw NSLocalizedString("Invalid drive size.", comment: "UTMData")
            }
            name = newDefaultDriveName(type: drive.imageType, forConfig: forConfig)
            let fileManager = FileManager.default
            let imagesPath = forConfig.imagesPath
            let dstPath = imagesPath.appendingPathComponent(name)
            if !fileManager.fileExists(atPath: imagesPath.path) {
                try fileManager.createDirectory(at: imagesPath, withIntermediateDirectories: false, attributes: nil)
            }
            
            // create drive
            // TODO: implement custom qcow2 creation
            let sema = DispatchSemaphore(value: 0)
            let imgCreate = UTMQemuImg()
            var success = false
            var msg = ""
            imgCreate.op = .create
            imgCreate.outputPath = dstPath
            imgCreate.sizeMiB = drive.size
            imgCreate.compressed = true
            imgCreate.start { (_success, _msg) in
                success = _success
                msg = _msg
                sema.signal()
            }
            sema.wait()
            if !success {
                throw msg
            }
        }
        
        DispatchQueue.main.async {
            let interface = drive.interface ?? UTMConfiguration.defaultDriveInterface()
            if drive.removable {
                forConfig.newRemovableDrive(drive.imageType, interface: interface)
            } else {
                forConfig.newDrive(name, type: drive.imageType, interface: interface)
            }
        }
    }
    
    func removeDrive(at: Int, forConfig: UTMConfiguration) throws {
        let fileManager = FileManager.default
        let path = forConfig.driveImagePath(for: at)!
        
        if fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
        
        DispatchQueue.main.async {
            forConfig.removeDrive(at: at)
        }
    }
    
    private func refreshConfiguration(for vm: UTMVirtualMachine) {
        guard let path = vm.path else {
            logger.error("Attempting to refresh unsaved VM \(vm.configuration.name)")
            return
        }
        guard let newVM = UTMVirtualMachine(url: path) else {
            logger.debug("Cannot create new object for \(path.path)")
            return
        }
        DispatchQueue.main.async {
            //self.objectWillChange.send()
            if let index = self.virtualMachines.firstIndex(of: vm) {
                self.virtualMachines.remove(at: index)
                self.virtualMachines.insert(newVM, at: index)
            } else {
                self.virtualMachines.insert(newVM, at: 0)
            }
            if self.selectedVM == vm {
                self.selectedVM = newVM
            }
        }
    }
    
    func busyWork(_ work: @escaping () throws -> Void) {
        DispatchQueue.main.async {
            self.busy = true
        }
        DispatchQueue.global(qos: .userInitiated).async {
            defer {
                DispatchQueue.main.async {
                    self.busy = false
                }
            }
            do {
                try work()
            } catch {
                logger.error("\(error)")
                DispatchQueue.main.async {
                    self.alertMessage = AlertMessage(error.localizedDescription)
                }
            }
        }
    }
}