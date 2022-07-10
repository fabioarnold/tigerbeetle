# VOPR and VOPR Hub Setup
Install Go:
```bash
sudo add-apt-repository ppa:longsleep/golang-backports
sudo apt update
sudo apt install golang-go
```

Add two users, namely voprrunner and voprhub. This creates separation between the two different functions of the server.

The voprrunner will continuously run the VOPR and send any bugs to the VOPR Hub.

This will require setting passwords for the respective users

```bash
sudo adduser voprhub
sudo adduser voprrunner
sudo usermod -aG sudo voprhub
sudo usermod -aG sudo voprrunner
```

## Set Up the VOPR Hub Component

Become the voprhub user
```bash
su - voprhub
```

Clone tigerbeetle
```bash
git clone https://github.com/coilhq/tigerbeetle.git
```

Install Zig
```bash
cd ./tigerbeetle
./scripts/install_zig.sh
cd ../
```

Create a second tigerbeetle directory here inside the hub directory which will run the VOPR Hub, then the initial tigerbeetle directory will be needed to replay seeds that the hub receives.
```bash
mkdir hub
cp -r tigerbeetle hub/tigerbeetle
```

Create a systemd service unit file for the VOPR Hub.
```bash
sudo nano /etc/systemd/system/voprhub.service
```
The file should contain the following (including an actual IP address and developer token with access to public repositories):
```bash
[Unit]

Description=Continously runs the VOPR Hub.

[Service]

User=voprhub
WorkingDirectory=/home/voprhub/hub/tigerbeetle/src/vopr_hub
Environment="REPOSITORY_URL=https://api.github.com/repos/coilhq/tigerbeetle/issues"
Environment="TIGERBEETLE_DIRECTORY=/home/voprhub/tigerbeetle"
Environment="VOPR_HUB_ADDRESS=<address>"
Environment="ISSUE_DIRECTORY=/home/voprhub"
Environment="DEVELOPER_TOKEN=******"
ExecStart=go run main.go
Restart=on-success

[Install]

WantedBy=multi-user.target
```

Start the VOPR Hub service
```bash
systemctl start voprhub.service
#Check it is up
systemctl status voprhub.service
# View logs e.g.
journalctl -f -n 100 -u voprhub.service
```

Go back to root user
```bash
exit
```

## Set Up the VOPR Component

Become voprrunner user
```bash
su - voprrunner
```

Create a script that will be used by the service to pull the latest code and run the VOPR.
```bash
sudo nano vopr_runner.sh
```

The file should contain the following (including an actual IP address):
```bash
#!/usr/bin/env bash
set -e

# Fetch the latest code
git pull

# Run the VOPR
zig/zig run ./src/vopr.zig -- --send="<address>" --simulations=5
```

Create four tigerbeetle directories here.

Note that the number of directories corresponds to the number of service instances that will run.

Ideally, this number should be increased/decreased to be two less than the number of CPU cores available.
```bash
git clone https://github.com/coilhq/tigerbeetle.git
# Install Zig
cd ./tigerbeetle
./scripts/install_zig.sh
cd ../
# Copy this directory to get four tigerbeetle directories.
cp -r tigerbeetle tigerbeetle1 # repeat with incrementing values for the other instances.
# Can remove original folder
rm -r tigerbeetle
```

Create a systemd service unit file.

Naming the file vopr@.service means it acts as a template that can reuse the same file to run different services that each target their own directories.
```bash
sudo nano /etc/systemd/system/vopr@.service
```

The file should contain the following:
```bash
[Unit]
Description=Continously runs the VOPR.
PartOf=vopr.target

[Service]

User=voprrunner
WorkingDirectory=/home/voprrunner/tigerbeetle%i
ExecStart=/home/voprrunner/vopr_runner.sh
Restart=on-success

[Install]

WantedBy=multi-user.target
```

Create a target file to manage all instances, called vopr.target.

Dependencies must be listed under Wants instead of Requires because requiring the services will cause them all to restart whenever one terminates.
```bash
sudo nano /etc/systemd/system/vopr.target
```

The file should contain the following:
```bash
[Unit]
Description=Runs all VOPR services.
Wants=vopr@1.service vopr@2.service vopr@3.service vopr@4.service

[Install]
WantedBy=multi-user.target
```

Start all services
```bash
systemctl start vopr.target
# Check it's up
systemctl status vopr.target
# Check individual services started up
systemctl status vopr@1.service
# View logs e.g.
journalctl -f -n 100 -u vopr@1.service
```
