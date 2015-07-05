<#
.SYNOPSIS
   Expands an EBS volume attached to an instance to make it larger.
 
.DESCRIPTION
   The process described here is followed to expand a volume:
   http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-expand-volume.html
   During the process your instance will be shutdown and restarted afterwards.

   On Ubunutu instances, typically the OS will automatically extend the volume
   at startup. On Windows instances, you are required to extend the volume on
   startup yourself, using the Disk Management applet.

.PARAMETER instanceName
    The instance name to extend, based on case-sensitively matching the Name
    tag.

.PARAMETER instanceId
    The instance Id to extend.

.PARAMETER size
    New size of the volume, in gibibytes. Must be larger than the current
    volume size.
 
.PARAMETER volumeId
    Optional volumeId to resize. If not specified, the cmdlet will extend the
    root volume attached to the instance.
    
.EXAMPLE
   EBS-ExpandDisk.ps1 -instanceName EC2-X01-0001 -size 40
   
   Resize first volume on an instance with Name tag of 'EC2-X01-0001' to 40GiB.

.EXAMPLE
   EBS-ExpandDisk.ps1 -instanceId i-a0093c13 -size 40 -volumeId vol-237e8ca

   Resize specific volume vol-237e8ca on instance Id i-a0093c13 to 40GiB.
 
.NOTES
   After volume expansion, an instance can take a long time to start up (eg. 5
   to 10 minutes for a typical 50GiB volume). This is normal.

   Specify your preferred AWS credential profile with Set-AWSCredentials. See
   http://docs.aws.amazon.com/powershell/latest/userguide/specifying-your-aws-credentials.html

.LINK
   http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-expand-volume.html

.LINK
   http://docs.aws.amazon.com/powershell/latest/userguide/specifying-your-aws-credentials.html
#>

[CmdletBinding(DefaultParametersetName="InstanceByName")] 

param
(
    [Parameter(Mandatory=$true, ParameterSetName="InstanceByName",Position=0)][string]$instanceName,
    [Parameter(Mandatory=$true, ParameterSetName="InstanceById",Position=0)][string]$instanceId,
    [Parameter(Mandatory=$true)][int]$size,
    [Parameter(Mandatory=$false)][string]$volumeId
)
        
Import-Module awspowershell


############################################
# Log
############################################

function Log([string]$info)
{
    $message = $info -f $args
    $date = Get-Date -f r
    Write-Host $date ":" $message
}


############################################
# Get instance Id from instance name
############################################

function GetInstanceIdFromName([string]$instancename)
{
    Log "Searching for instance name: $instancename"

    # Get instance by name tag
    $selectedInstances = Get-EC2Instance -Filter @{name="tag:Name"; values="$instanceName"} | Select-Object -ExpandProperty instances
    If ($selectedInstances -eq $null)
    {
        Log "AWS Instance Name: $instanceName not found. Instance names are case sensitive."
        Exit
    }
    else
    {
        $selectedInstance = $selectedInstances[0].InstanceId
    }

    Log "Found $instanceName resolves to instanceId: $selectedInstance"
    return $selectedInstance
}


############################################
# Get instance name by instance Id
############################################

function GetNameFromInstanceId([string]$instanceId)
{
    Log "Searching for instance Id: $instanceId"

    # Get instance
    $selectedInstance = Get-EC2Instance -Instance $instanceId
    If ($selectedInstance -eq $null)
    {
        Log "AWS Instance Id: $instanceId not found."
        Exit
    }

    # Get tags looking for "Name". If not found, return the instance Id as the name.
    $tags = (Get-EC2Instance -Instance $instanceId).Instances.Tags
    ForEach ($tag in $tags)
    {
        $tagName = $($tag.Key)
        $tagValue = $($tag.Value)
        If ($tagName -eq "Name")
        {
            Log "Found $instanceId with name $tagValue"
            return $tagValue
        }
    }

    Log "Found $instanceId with no name - using instanceId as name."
    return $instanceId
}


############################################
# Check shut down behaviour
############################################

function CheckShutdownBehavior($instanceId)
{
    Log ""
    Log "Checking instance initiated shutdown behavior..."
    $instanceAttribute = Get-EC2InstanceAttribute -InstanceId $instanceId -Attribute "instanceInitiatedShutdownBehavior"
    Log "Behavior is '$($instanceAttribute.InstanceInitiatedShutdownBehavior)'"
    If ($instanceAttribute.InstanceInitiatedShutdownBehavior -ne "stop")
    {
        Log "Instance shutdown behaviour must be set to 'stop', otherwise stopping the instance would delete any volumes."
        Exit
    }
}


############################################
# Stop the instance if it is running
############################################

function StopInstance
{
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]

    param
    (
        [string]$instanceId
    )

    Log ""
    $state = (Get-EC2Instance -Instance $instanceId).Instances.State.Name
    Log "Current state of instance is: $state"

    $stopRequested = $false
    switch ($state)
    {
        "running"
        {
            Log "Stopping instance..."
            if ($pscmdlet.ShouldProcess($instanceId, "Are you sure you want to stop instance $instanceId ?`nIt is recommended to stop prior to snapshot for volume consistency.", "Are you sure?"))
            {
                Stop-EC2Instance -Instance $instanceId | Out-Null
                $stopRequested = $true
            }
        }
        "stopped"
        {
            Log "Instance already stopped."
        }
        "stopping"
        {
            Log "Instance stopping..."
        }
        default
        {
            Log "Unknown instance state: $state"
            Exit
        }
    }

    # Start polling until the state is stopped
    While ($state -ne "stopped" -and $stopRequested)
    {
        Log "State of instance is: $state"
        Start-Sleep -Seconds 5
        $state = (Get-EC2Instance -Instance $instanceId).Instances.State.Name
    }
}


############################################
# Get appropriate volume ID to snapshot
############################################

function GetVolume
{
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]

    param
    (
        [string]$instanceId, [string]$volumeId
    )

    Log ""
    $volumes = Get-EC2Volume -Filter @{name="attachment.instance-id"; values="$instanceId"}
    $rootDeviceName = (Get-EC2Instance -Instance $instanceId).Instances.RootDeviceName
    $requestedVolume = $null

    ForEach ($volume in $volumes)
    {
        Log "Attached volume: $($volume.VolumeId) - is root device: $($volume.Attachment[0].Device -eq $rootDeviceName), type $($volume.VolumeType.Value) at $($volume.Size)GiB attached to $($volume.Attachment[0].Device)"
    }

    ForEach ($volume in $volumes)
    {
        If ($volumeId -ne "" -and $volume.VolumeId -eq $volumeId)
        {
            Log "Using requested volume: $($volume.VolumeId)"
            $requestedVolume = $volume
        }
        If ($volumeId -eq "" -and $volume.Attachment[0].Device -eq $rootDeviceName)
        {
            Log "Using root volume: $($volume.VolumeId)"
            $requestedVolume = $volume
        }
    }

    # No volume found?
    If ($requestedVolume -eq $null)
    {
        If ($volumeId -ne "")
        {
            Log "Requested volume '$volumeId' not found."
            Exit
        }
        If ($volumeId -eq "")
        {
            Log "No root volume found!"
            Exit
        }
    }

    # Check volume size against requested new size, make sure it's 
    If ($requestedVolume.Size -ge $size)
    {
        Log "New volume size needs to be greated than $($requestedVolume.Size)GiB."
        Exit
    }

    if ($pscmdlet.ShouldProcess($($requestedVolume.VolumeId), "Are you sure you want to resize volume $($requestedVolume.VolumeId) ?`nIs root device: $($requestedVolume.Attachment[0].Device -eq $rootDeviceName), type $($requestedVolume.VolumeType.Value) at $($requestedVolume.Size)GiB attached to $($requestedVolume.Attachment[0].Device)", "Are you sure?") -eq $false)
    {
        Log "Aborting resize."
        Exit
    }

    return $requestedVolume.VolumeId
}


############################################
# Create a tag on a resource
############################################

function Add-EC2Tag 
{
    Param
    (
        [string][Parameter(Mandatory=$True)]$key,
        [string][Parameter(Mandatory=$True)]$value,
        [string][Parameter(Mandatory=$True)]$resourceId
    )
 
    $Tag = New-Object amazon.EC2.Model.Tag
    $Tag.Key = $Key
    $Tag.Value = $value
 
    New-EC2Tag -ResourceId $resourceId -Tag $Tag | Out-Null
}


############################################
# Create a snapshot of the volume
############################################

function CreateSnapshot([string]$volumeId, [string]$instanceName, [string]$instanceId)
{
    Log ""
    Log "Creating snapshot of volume: $volumeId for instance $instanceName ($instanceId)"
    $snapshot = New-EC2Snapshot -VolumeId $volumeId -Description "ebs_expand_$instanceName($instanceId)"

    # Get tags of the instance and clone onto the snapshot
    $tags = (Get-EC2Instance -Instance $instanceId).Instances.Tags
    ForEach ($tag in $tags)
    {
        $tagName = $($tag.Key)
        $tagValue = $($tag.Value)
        switch ($tagName)
        {
            "Name"
            {
                $tagName = "ec2Name"
            }
        }

        Log "Adding snapshot tag: '$tagName' with value '$tagValue'"
        Add-EC2Tag -key $tagName -value $tagValue -resourceId $snapshot.SnapshotId
    }

    $tagName = "Name"
    $tagValue = "snap-$volumeId"
    Log "Adding snapshot tag: '$tagName' with value '$tagValue'"
    Add-EC2Tag -key $tagName -value $tagValue -resourceId $snapshot.SnapshotId

    # Poll for the snapshot to be finished
    $snapState = Get-EC2Snapshot -SnapshotIds $snapshot.SnapshotId
    While ($($snapState.State.Value) -ne "completed")
    {
        Log "Waiting for snapshot to complete - current state is $($snapState.Status.Value) ($($snapState.Progress))"
        Start-Sleep -Seconds 30
        $snapState = Get-EC2Snapshot -SnapshotIds $snapshot.SnapshotId
    }

    Log "Snapshot completed - current state is $($snapState.Status.Value) ($($snapState.Progress))"
    return $snapshot.SnapshotId
}


############################################
# Restore snapshot to a new volume
############################################

function RestoreSnapshot([string]$snapshotId, [int]$size, [string]$volumeId)
{
    Log ""
    $volume = Get-EC2Volume -VolumeIds $volumeId
    Log "Current volume is in availability zone: $($volume.AvailabilityZone)"

    Log "Creating new volume of type $($volume.VolumeType) with size $($size)GiB from snapshot $snapshotId in availability zone $($volume.AvailabilityZone)..."
    $newVolume = New-EC2Volume -SnapshotId $snapshotId -Size $size -AvailabilityZone $($volume.AvailabilityZone) -VolumeType $($volume.VolumeType)
    Log "New volume Id: $($newVolume.VolumeId)"

    # Get tags of the original volume and clone onto the new volume
    $tags = $volume.Tags
    ForEach ($tag in $tags)
    {
        $tagName = $($tag.Key)
        $tagValue = $($tag.Value)
        Log "Adding volume tag: '$tagName' with value '$tagValue'"
        Add-EC2Tag -key $tagName -value $tagValue -resourceId $newVolume.VolumeId
    }

    # Poll until the new volume is ready
    While ($($newVolume.State) -ne "available")
    {
        Log "Waiting for new volume to be provisioned - current state is $($newVolume.State)"
        Start-Sleep -Seconds 30
        $newVolume = Get-EC2Volume -VolumeIds $newVolume.VolumeId
    }

    Log "New volume created OK."
    return $newVolume.VolumeId
}


############################################
# Detach the old and attach the new volume
############################################

function DetachAndAttach([string]$instanceId, [string]$instanceName, [string]$volumeId, [string]$newVolumeId)
{
    Log ""
    $volume = Get-EC2Volume -VolumeIds $volumeId
    $device = $volume.Attachment[0].Device

    Log "Detaching old volume $volumeId from $instanceName on $device..."
    $volAttachment = Dismount-EC2Volume -InstanceId $instanceId -VolumeId $volumeId -Device $device

    # Poll until the new volume is detached
    $volume = Get-EC2Volume -VolumeIds $volumeId
    While ($($volume.Attachment[0].State.Value) -ne $null)
    {
        Log "Waiting for old volume to be detached - current state is $($volume.Attachment[0].State.Value)"
        Start-Sleep -Seconds 5
        $volume = Get-EC2Volume -VolumeIds $volumeId
    }

    Log ""
    Log "Attaching new volume $newVolumeId to $instanceName as $device..."
    $volume = Add-EC2Volume -InstanceId $instanceId -VolumeId $newVolumeId -Device $device

    # Poll until the new volume is attached
    $volume = Get-EC2Volume -VolumeIds $newVolumeId
    While ($($volume.Attachment[0].State.Value) -ne "attached")
    {
        Log "Waiting for new volume to be attached - current state is $($volume.Attachment[0].State.Value)"
        Start-Sleep -Seconds 5
        $volume = Get-EC2Volume -VolumeIds $newVolumeId
    }
}


############################################
# Start the instance if it is stopped
############################################

function StartInstance
{
    [CmdletBinding(SupportsShouldProcess=$true, ConfirmImpact="High")]

    param
    (
        [string]$instanceId
    )

    Log ""
    $state = (Get-EC2Instance -Instance $instanceId).Instances.State.Name
    Log "Current state of instance is: $state"

    $startRequested = $false
    switch ($state)
    {
        "stopped"
        {
            Log "Starting instance..."
            if ($pscmdlet.ShouldProcess($instanceId, "Are you sure you want to start instance $instanceId ?", "Are you sure?"))
            {
                Start-EC2Instance -Instance $instanceId | Out-Null
                $startRequested = $true
            }
        }
        "running"
        {
            Log "Instance already running?"
        }
        "starting"
        {
            Log "Instance starting..."
        }
        default
        {
            Log "Unknown instance state: $state"
            Exit
        }
    }

    # Start polling until the state is started
    While ($state -ne "running" -and $startRequested)
    {
        Log "State of instance is: $state"
        Start-Sleep -Seconds 5
        $state = (Get-EC2Instance -Instance $instanceId).Instances.State.Name
    }
}


############################################
# Main entry point
############################################

# Get instance Id
switch ($PsCmdlet.ParameterSetName) 
{
    "InstanceByName"
    {
        $instanceId = GetInstanceIdFromName $instanceName
    }
    "InstanceById"
    {
        $instanceName = GetNameFromInstanceId $instanceId
    }
}

# Make sure shutting down won't delete volumes
CheckShutdownBehavior $instanceId

# Find relevant volume - use root volume if a volume Id hasn't been specified
$volumeId = GetVolume $instanceId $volumeId

# Stop instance if running
StopInstance $instanceId

# Create a snapshot
$snapshotId = CreateSnapshot $volumeId $instanceName $instanceId

# Restore the snapshot to a new volume in the same availability zone
$newVolumeId = RestoreSnapshot $snapshotId $size $volumeId

# Detach the old volume and attach the new volume
DetachAndAttach $instanceId $instanceName $volumeId $newVolumeId

# Start instance
StartInstance $instanceId

# All done
Log ""
Log "All done. You should now login to your instance and resize your filesystem as appropriate."
Log ""
Log "On Ubuntu you should run df -h to confirm the size of the new volume is correct."
Log "If not, grab the device name and then run sudo resize2fs /dev/[deviceName]"
Log "Finally confirm the new volume size by running df -h once more."
Log ""
Log "In Windows you should use the Computer Management applet followed by Disk Management."
Log "Right click on the volume, click Extend Volume and accept the defaults in the wizard."
Log ""
Log "NOTE: The following items should be deleted once you're happy with the new volume on your instance:"
Log ""
Log "Delete snapshot:   $snapshotId"
Log "Delete old volume: $volumeId"
