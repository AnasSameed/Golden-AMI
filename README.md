# Golden AMI: build once, launch many

A small AWS project that **bakes a custom Amazon Machine Image (AMI)** with scripts instead of console clicking, then proves it works by launching instances that serve a live status page with **no setup at launch**.

![Architecture](docs/architecture.png)

## What it does

- Launches a temporary **builder** instance on Amazon Linux 2023 and runs `user-data/bake.sh` on it.
- The script patches the OS, installs and hardens Apache, deploys a demo website and registers a boot-time service.
- The builder **stops itself** when finished, so the AMI is created from a clean, stopped disk.
- Creates the **AMI + EBS snapshot**, then terminates the builder.
- Launches test instances from the AMI and checks `/health.html` until they respond.
- Removes everything with one cleanup script.

Everything runs from **AWS CloudShell**, which is already signed in, so **no access keys are needed or stored**.

## Why a golden AMI?

Installing software every time an instance starts (user data) is slow and can fail halfway. A pre-baked AMI makes new instances **start ready to serve**, identical every time. It is the basis for fast Auto Scaling groups.

## Bake time vs boot time

The key design idea is knowing **what belongs in the image** and **what must be created per instance**.

| Baked into the AMI (same for every clone) | Generated at boot (unique per instance) |
|---|---|
| OS patches, Apache, hardening config | Instance ID, private IP, hostname |
| The website files | Availability Zone, instance type |
| Build time, base AMI, Apache version (`build.json`) | `info.json`, written by `instance-info.service` on every boot |

Launch two instances (`COUNT=2`) and refresh both pages: the **baked values match, the boot values differ**.

## Repository layout

```
golden-ami/
├── user-data/bake.sh          # everything installed into the image
├── scripts/
│   ├── common.sh              # shared settings (Region, tags)
│   ├── build-ami.sh           # builder -> bake -> AMI
│   ├── launch-from-ami.sh     # launch + health check
│   └── cleanup.sh             # delete everything tagged Project=golden-ami
├── docs/architecture.png
└── README.md
```

## Quick start (AWS CloudShell)

1. Sign in to the AWS console, pick your Region, and open **CloudShell** (the `>_` icon in the footer).
2. Run:

```bash
git clone https://github.com/AnasSameed/golden-ami.git
cd golden-ami

bash scripts/build-ami.sh          # ~5-8 minutes: bake, snapshot, AMI
bash scripts/launch-from-ami.sh    # launches a test instance, prints its URL
```

3. Open the printed `http://<public-ip>` URL (use **http**, not https).

To compare two clones:

```bash
COUNT=2 bash scripts/launch-from-ami.sh
```

4. When finished:

```bash
bash scripts/cleanup.sh            # asks you to type "yes"
```

## Console-only alternative

No CLI needed: paste `user-data/bake.sh` into **User data** when launching an Amazon Linux 2023 instance, wait until it stops on its own, then use **Actions > Image and templates > Create image**. Launch from that AMI with empty user data and port 80 allowed.

## What you should see

- The builder appears, then stops by itself, then is terminated.
- A new AMI named `golden-web-<timestamp>` appears under **EC2 > AMIs**.
- The test instance's page shows its own instance ID in the top section, and build details in the lower section.

## Design decisions and security notes

- **No credentials stored.** CloudShell provides the session. Nothing secret is in this repo.
- **IMDSv2 required** (`HttpTokens=required`) on every instance, and the scripts use token-based metadata calls.
- **Stop, then image.** The builder shuts itself down on exit (success or failure), so the AMI is taken from a consistent, quiescent disk with no reboot race.
- **`cloud-init clean` before imaging** so each clone runs first-boot setup (including new SSH host keys) fresh.
- **Per-instance data is never baked.** `info.json` is deleted before imaging and rebuilt at each boot.
- **Everything is tagged** `Project=golden-ami`, which is how `cleanup.sh` finds it. Do not reuse that tag on resources you want to keep.
- The demo security group opens **port 80 to the internet** because it serves a public demo page. It shows instance details (ID, AZ, IPs), which is fine for a demo but should not be exposed like this in production.
- SSH is not opened at all. Use EC2 Instance Connect or Session Manager if you need a shell.

## Cost

A few cents if cleaned up: a `t3.micro` builder for a few minutes, a `t3.micro` test instance while it runs, and an 8 GiB snapshot while the AMI exists. Public IPv4 addresses are billed by the hour. **Run `cleanup.sh` when done**, and check **EC2 > Instances, AMIs, Snapshots** afterwards.

## Troubleshooting

| Symptom | What to check |
|---|---|
| `No AWS Region set` | `export AWS_REGION=eu-north-1` (or your Region) |
| `AccessDenied` | The signed-in user needs EC2 and `ssm:GetParameter` permissions |
| `No default VPC` | Create a default VPC or edit the scripts to pass a subnet |
| Wait for builder times out | `aws ec2 get-console-output --instance-id <id> --latest --output text \| tail -50` |
| Health check says DOWN | Wait a minute; confirm the security group allows port 80 and you used `http` |
| Need to look inside an instance | EC2 Instance Connect, then `sudo systemctl status httpd instance-info` and `sudo journalctl -u instance-info` |

## Roadmap

- [ ] Put the AMI behind an **Application Load Balancer** and an **Auto Scaling group** across two Availability Zones
- [ ] Rebuild the image with **HashiCorp Packer** or **EC2 Image Builder**
- [ ] Encrypt the AMI and **copy it to a second Region**
- [ ] Add the **CloudWatch agent** and Session Manager access through an instance role
- [ ] Express the whole stack in **Terraform** or CloudFormation
- [ ] Replace broad permissions with a **least-privilege IAM policy** for the build user
