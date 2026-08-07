//
//  main.swift
//  AltDaemon
//
//  Created by Riley Testut on 6/2/20.
//  Copyright © 2020 Riley Testut. All rights reserved.
//

import Foundation

private func runAnisetteSelfTest() -> Never
{
    Task {
        do
        {
            let anisetteData = try await AnisetteDataManager.shared.requestAnisetteData()
            print("AltDaemon anisette self-test passed (MID length: \(anisetteData.machineID.count), OTP length: \(anisetteData.oneTimePassword.count)).")
            exit(EXIT_SUCCESS)
        }
        catch
        {
            let message = "AltDaemon anisette self-test failed: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(EXIT_FAILURE)
        }
    }

    dispatchMain()
}

if ProcessInfo.processInfo.arguments.contains("--self-test-anisette")
{
    runAnisetteSelfTest()
}

autoreleasepool {
    DaemonConnectionManager.shared.start()
    RunLoop.current.run()
}
