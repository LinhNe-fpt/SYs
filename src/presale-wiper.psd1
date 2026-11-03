@{
    RootModule           = 'presale-wiper.psm1'
    ModuleVersion        = '0.1.0'
    GUID                 = 'c1f4a6b2-7d3e-4f19-9a58-2b6d0e5c4a71'
    Author               = 'presale-wiper'
    Description          = 'Quét và dọn môi trường lập trình trên Windows trước khi bán/thanh lý máy. Mặc định dry-run.'
    PowerShellVersion    = '5.1'
    CompatiblePSEditions = @('Desktop', 'Core')

    FunctionsToExport = @(
        # config
        'Initialize-PswConfig'
        'Get-PswConfig'
        'Get-PswLookup'
        'Get-PswDefault'
        'New-PswLookupSet'
        # paths
        'ConvertTo-PswLongPath'
        'ConvertFrom-PswLongPath'
        'Remove-PswLongPathPrefix'
        'Get-PswFullPath'
        'Resolve-PswRootPath'
        'Test-PswPathExists'
        'Test-PswSamePath'
        'Test-PswPathIsUnder'
        'Get-PswParentPath'
        'Join-PswPath'
        'Get-PswPathDepth'
        'Get-PswRelativePath'
        'Test-PswIsReparsePoint'
        'Get-PswFileSystemInfos'
        # size
        'Reset-PswSizeCache'
        'Measure-PswDirectorySize'
        'Measure-PswEntrySize'
        'Format-PswSize'
        'ConvertTo-PswSizeText'
        # classify
        'Get-PswEntryKinds'
        'Get-PswExtension'
        'Get-PswFileKind'
        'Test-PswIsProjectMarker'
        'Test-PswIsDevDirName'
        'Test-PswIsSkipDirName'
        'Test-PswIsSecretDirName'
        'New-PswFolderProfile'
        'Get-PswFolderKind'
        'Add-PswChildToProfile'
        'Get-PswEntryKindFromName'
        # guard
        'Get-PswSystemSubtrees'
        'Get-PswExactForbidden'
        'Clear-PswGuardCache'
        'Get-PswProtectionReason'
        'Test-PswProtectedPath'
        'Test-PswShallowPath'
        'Get-PswScanRootBlockReason'
        'Test-PswElevated'
        'Get-PswRunningEditorProcesses'
        # walk
        'New-PswScanOptions'
        'New-PswEntry'
        'Test-PswExcluded'
        'Invoke-PswScan'
        'Get-PswDefaultScanRoots'
        'Get-PswTruncatedText'
        # report
        'Get-PswScanSummary'
        'Get-PswDisplayPath'
        'Format-PswTable'
        'ConvertTo-PswTableColumn'
        'Write-PswScanReport'
        'ConvertTo-PswReportObject'
        'Write-PswJsonReport'
        'Get-PswVersion'
        # log
        'New-PswLogSession'
        'Add-PswLogEntry'
        'Close-PswLogSession'
        'Get-PswLogSession'
        'Read-PswLogFile'
        'Invoke-PswLogRotation'
        'Test-PswContainerPath'
        # cli
        'Invoke-PswCli'
        'Invoke-PswScanCommand'
        'Invoke-PswVerifyCommand'
        'Invoke-PswReportCommand'
        'Get-PswUsage'
        'ConvertTo-PswByteSize'
        'Select-PswArgumentSet'
    )

    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
}
