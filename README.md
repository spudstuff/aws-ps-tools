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
Resize first volume on an instance with Name tag of 'EC2-X01-0001' to 40GiB.

````EBS-ExpandDisk.ps1 -instanceName EC2-X01-0001 -size 40````
   
Resize specific volume vol-237e8ca on instance Id i-a0093c13 to 40GiB.

````EBS-ExpandDisk.ps1 -instanceId i-a0093c13 -size 40 -volumeId vol-237e8ca````

 
#### Notes
After volume expansion, an instance can take a long time to start up (eg. 5
to 10 minutes for a typical 50GiB volume). This is normal.

Specify your preferred AWS credential profile with Set-AWSCredentials. See
http://docs.aws.amazon.com/powershell/latest/userguide/specifying-your-aws-credentials.html
