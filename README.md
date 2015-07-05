# aws-ps-tools
A set of AWS PowerShell tools.

### EBS-ExpandDisk.ps1
Expands an EBS volume attached to an instance to make it larger.

The process described here is followed to expand a volume:
http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ebs-expand-volume.html.
During the process your instance will be shutdown and restarted afterwards.

On Ubunutu instances, typically the OS will automatically extend the volume
at startup. On Windows instances, you are required to extend the volume on
startup yourself, using the Disk Management applet.

#### Usage
```
EBS-ExpandDisk.ps1 -instanceId <String> -size <Int32> [-volumeId <String>]
EBS-ExpandDisk.ps1 -instanceName <String> -size <Int32> [-volumeId <String>]
```

Where:
* **instanceId** - The instance Id to extend.
* **instanceName** - The instance name to extend, based on case-sensitively matching the Name tag.
* **size** - New size of the volume, in gibibytes. Must be larger than the current volume size.
* **volumeId** - Optional volumeId to resize. If not specified, the cmdlet will extend the root volume attached to the instance.

One of instanceId or instanceName is required.

#### Examples
Resize first volume on an instance with Name tag of 'EC2-X01-0001' to 40GiB.

```EBS-ExpandDisk.ps1 -instanceName EC2-X01-0001 -size 40```
   
Resize specific volume vol-237e8ca on instance Id i-a0093c13 to 40GiB.

```EBS-ExpandDisk.ps1 -instanceId i-a0093c13 -size 40 -volumeId vol-237e8ca```

 
#### Notes
After volume expansion, an instance can take a long time to start up (eg. 5
to 10 minutes for a typical 50GiB volume). This is normal.

Specify your preferred AWS credential profile with Set-AWSCredentials. See
http://docs.aws.amazon.com/powershell/latest/userguide/specifying-your-aws-credentials.html

The following permissions are required on your IAM account:

```
"ec2:AttachVolume",
"ec2:CreateSnapshot",
"ec2:CreateTags",
"ec2:CreateVolume",
"ec2:DescribeInstances",
"ec2:DescribeInstanceAttribute"
"ec2:DescribeSnapshots",
"ec2:DescribeTags",
"ec2:DescribeVolumes",
"ec2:DetachVolume",
"ec2:StartInstances",
"ec2:StopInstances"
```

And if you want to later delete the snapshot and old volume, you also need:

```
"ec2:DeleteSnapshot",
"ec2:DeleteVolume"
```