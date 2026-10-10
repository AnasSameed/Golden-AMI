#!/bin/bash
# bake.sh - turns a fresh Amazon Linux 2023 instance into the "golden" web server image.
#
# Runs as EC2 user data on a temporary builder instance. When it finishes (success OR
# failure) the instance shuts itself down, so the AMI is created from a stopped,
# consistent disk and no manual waiting is needed.
set -euxo pipefail
exec > >(tee -a /var/log/bake.log) 2>&1     # keep a copy of everything, inside the image
trap 'echo "bake exit code: $?"; sync; shutdown -h now' EXIT

WEB_ROOT=/var/www/html

# ---------------------------------------------------------------- 1. OS + web server
dnf update -y
dnf install -y httpd

# ---------------------------------------------------------------- 2. Apache hardening
cat > /etc/httpd/conf.d/99-hardening.conf <<'CONF'
ServerTokens Prod
ServerSignature Off
TraceEnable Off
<IfModule mod_headers.c>
    Header always set X-Content-Type-Options "nosniff"
    Header always set X-Frame-Options "SAMEORIGIN"
    Header always set Referrer-Policy "no-referrer"
</IfModule>
CONF
httpd -t    # fail the bake now if the config is broken, not at first boot

# ---------------------------------------------------------------- 3. Per-instance info
# Anything unique to ONE instance (id, AZ, IP) must be generated at boot, never baked.
cat > /usr/local/bin/instance-info.sh <<'SCRIPT'
#!/bin/bash
# Writes details of the running instance to info.json using IMDSv2.
set -euo pipefail
OUT="${OUT_DIR:-/var/www/html}/info.json"
IMDS=http://169.254.169.254/latest
TOKEN=$(curl -sf --retry 5 --retry-delay 2 -X PUT "$IMDS/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 120")
md() { curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/$1"; }

INSTANCE_ID=$(md instance-id)
INSTANCE_TYPE=$(md instance-type)
AZ=$(md placement/availability-zone)
PRIVATE_IP=$(md local-ipv4)
HOSTNAME_=$(md hostname)
AMI_ID=$(md ami-id)

TMP=$(mktemp "${OUT}.XXXXXX")
cat > "$TMP" <<JSON
{
  "instance_id": "$INSTANCE_ID",
  "instance_type": "$INSTANCE_TYPE",
  "availability_zone": "$AZ",
  "private_ip": "$PRIVATE_IP",
  "hostname": "$HOSTNAME_",
  "ami_id": "$AMI_ID"
}
JSON
chmod 644 "$TMP"
mv "$TMP" "$OUT"
SCRIPT
chmod 755 /usr/local/bin/instance-info.sh

cat > /etc/systemd/system/instance-info.service <<'UNIT'
[Unit]
Description=Write this instance's metadata to the web root
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/instance-info.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT

# ---------------------------------------------------------------- 4. The website
cat > "$WEB_ROOT/index.html" <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Golden AMI</title>
<style>
:root{--bg:#f6f7f9;--card:#fff;--ink:#1c2430;--mute:#667085;--line:#e4e7ec;--accent:#ff9900}
@media (prefers-color-scheme:dark){:root{--bg:#10151c;--card:#18202a;--ink:#e8edf3;--mute:#9aa6b5;--line:#2a3441}}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif}
main{max-width:860px;margin:0 auto;padding:40px 20px 60px}
h1{margin:0 0 4px;font-size:2rem}
.sub{color:var(--mute);margin:0 0 28px}
.badge{display:inline-block;background:var(--accent);color:#1c2430;font-weight:600;font-size:.75rem;padding:2px 10px;border-radius:99px;margin-bottom:12px}
h2{font-size:.85rem;text-transform:uppercase;letter-spacing:.06em;color:var(--mute);margin:28px 0 10px}
.grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(220px,1fr));gap:12px}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:14px 16px}
.card b{display:block;font-size:.72rem;color:var(--mute);font-weight:600;text-transform:uppercase;letter-spacing:.05em}
.card span{font:600 .92rem ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;word-break:break-all}
ol{padding-left:20px} li{margin:6px 0}
footer{margin-top:36px;color:var(--mute);font-size:.85rem}
</style>
</head>
<body><main>
<span class="badge">GOLDEN AMI</span>
<h1>Hello from a pre-baked image</h1>
<p class="sub">This server booted from a custom AMI. Nothing was installed at launch.</p>
<h2>Generated at boot (this instance)</h2>
<div class="grid" id="boot">Loading...</div>
<h2>Baked into the AMI (build time)</h2>
<div class="grid" id="baked">Loading...</div>
<h2>How it works</h2>
<ol>
<li>A temporary builder instance runs <code>bake.sh</code>: patches the OS, installs Apache and adds this page.</li>
<li>The builder stops itself, then an AMI (plus an EBS snapshot) is created from its disk.</li>
<li>Every instance launched from the AMI is a ready-to-serve clone. A systemd service refreshes the "this instance" values on each boot.</li>
</ol>
<footer>Launch a second instance from the same AMI and compare: the baked values stay identical, the instance values change.</footer>
</main>
<script>
const labels={instance_id:"Instance ID",instance_type:"Instance type",availability_zone:"Availability Zone",private_ip:"Private IP",hostname:"Hostname",ami_id:"AMI ID",built_at:"Built at (UTC)",base_ami:"Base AMI",httpd:"Apache version",os:"Operating system"};
function render(id,url,keys){
  fetch(url,{cache:"no-store"}).then(r=>{if(!r.ok)throw 0;return r.json()}).then(d=>{
    const box=document.getElementById(id);box.textContent="";
    keys.forEach(k=>{const c=document.createElement("div");c.className="card";
      const b=document.createElement("b");b.textContent=labels[k];
      const s=document.createElement("span");s.textContent=d[k]||"unknown";
      c.append(b,s);box.append(c)});
  }).catch(()=>{document.getElementById(id).textContent="Not available yet. Refresh in a few seconds."});
}
render("boot","info.json",["instance_id","instance_type","availability_zone","private_ip","hostname","ami_id"]);
render("baked","build.json",["built_at","base_ami","httpd","os"]);
</script>
</body></html>
HTML
echo "OK" > "$WEB_ROOT/health.html"

# Build facts that stay the same for every instance launched from this AMI
IMDS=http://169.254.169.254/latest
TOKEN=$(curl -sf -X PUT "$IMDS/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 120")
BASE_AMI=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" "$IMDS/meta-data/ami-id")
BUILT_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
HTTPD_VERSION=$(rpm -q --qf '%{VERSION}' httpd)
OS_NAME=$(. /etc/os-release && echo "$PRETTY_NAME")
cat > "$WEB_ROOT/build.json" <<JSON
{
  "built_at": "$BUILT_AT",
  "base_ami": "$BASE_AMI",
  "httpd": "$HTTPD_VERSION",
  "os": "$OS_NAME"
}
JSON
chmod 644 "$WEB_ROOT"/*

# ---------------------------------------------------------------- 5. Services
systemctl daemon-reload
systemctl enable httpd instance-info.service      # start on every boot (not now)

# ---------------------------------------------------------------- 6. Image hygiene
dnf clean all
rm -f "$WEB_ROOT/info.json"                       # must not carry the builder's identity
rm -f /root/.bash_history /home/ec2-user/.bash_history
cloud-init clean --logs                           # new instances run first-boot setup fresh
echo "bake complete"
