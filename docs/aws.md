# AWS security extension

The main lab runs locally. The AWS module is an undeployed reference profile for a dedicated commercial AWS sandbox account. Every AWS resource is count-gated by `enable_cloud`, which defaults to false. The provider checks the expected account ID. If cloud deployment is approved later, the workload trust principal must belong to that same account.

| Local control | AWS counterpart |
| --- | --- |
| Dedicated libvirt network and guest firewall | VPC with two private subnets, no internet or NAT gateway, and security group references for HTTPS to the private AWS interfaces |
| Namespace least-privilege identity | One existing workload role may assume the lab role. That role can read one secret through the designated VPC endpoint and decrypt through Secrets Manager with the named encryption context. |
| K3s Secret encryption and mounted key | Secrets Manager metadata protected by a rotating customer-managed KMS key. The secret value is entered as a separate approved operation and stays outside OpenTofu state. |
| Kubernetes audit log | Multi-region CloudTrail management events, digest validation, a separately encrypted versioned S3 archive, TLS enforcement, and trail-specific grants |
| Host and CI configuration checks | OpenTofu validation and Trivy IaC checks execute without AWS deployment credentials in the intended pipeline. |

The private interface endpoints cover both regional STS and Secrets Manager. An approved workload would use a regional STS endpoint and an existing workload identity with the corresponding identity policy. The lab module creates no workload instances. The CloudTrail audit bucket prevents accidental destruction and needs separate review of log retention before removal. Endpoint, KMS, Secrets Manager, and audit services can incur charges when enabled.

The following commands validate source and provider configuration on a network-enabled machine. They download providers and make no AWS resources.

```bash
tofu -chdir=infra/aws init -backend=false
tofu -chdir=infra/aws validate
trivy config --severity HIGH,CRITICAL --exit-code 1 infra/aws
```

AWS API delivery, IAM simulation, secret access, VPC connectivity, and cloud costs were not exercised in this project. Account-specific deployment awaits explicit authorization.

- AWS audit delivery and key conditions used by the module. [CloudTrail S3 policy](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/create-s3-bucket-policy-for-cloudtrail.html) · [CloudTrail and KMS](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/how-kms-works-with-cloudtrail.html)
