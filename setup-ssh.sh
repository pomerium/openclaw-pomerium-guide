#!/bin/bash
set -e

echo "=================================================="
echo "OpenClaw + Pomerium SSH Setup Script"
echo "=================================================="
echo ""

# Check if we're in the right directory
if [ ! -f "docker-compose.yml" ]; then
    echo "❌ Error: docker-compose.yml not found!"
    echo "   Please run this script from the repository root directory."
    exit 1
fi

# Check if openclaw-data directory exists
if [ ! -d "openclaw-data" ]; then
    echo "❌ Error: openclaw-data directory not found!"
    echo "   Please ensure the repository is properly set up."
    exit 1
fi

echo "✓ Repository structure validated"
echo ""

# Step 1: Generate SSH keys
echo "=================================================="
echo "Step 1: Generating SSH Keys for Pomerium"
echo "=================================================="
echo ""
echo "This will generate all keys in the repository root for security."
echo "Only the User CA public key will be copied to the container."
echo ""

# Check if keys already exist
KEYS_EXIST=false
if [ -f "pomerium_user_ca_key" ] || \
   [ -f "ssh_host_ed25519_key" ] || \
   [ -f "ssh_host_rsa_key" ] || \
   [ -f "ssh_host_ecdsa_key" ]; then
    KEYS_EXIST=true
fi

if [ "$KEYS_EXIST" = true ]; then
    echo "⚠️  Warning: Some SSH keys already exist!"
    echo ""
    [ -f "pomerium_user_ca_key" ] && echo "  Found: pomerium_user_ca_key"
    [ -f "ssh_host_ed25519_key" ] && echo "  Found: ssh_host_ed25519_key"
    [ -f "ssh_host_rsa_key" ] && echo "  Found: ssh_host_rsa_key"
    [ -f "ssh_host_ecdsa_key" ] && echo "  Found: ssh_host_ecdsa_key"
    echo ""
    read -p "Do you want to regenerate them? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping key generation..."
        SKIP_KEYGEN=true
    fi
fi

if [ "$SKIP_KEYGEN" != "true" ]; then
    echo "Generating User CA key pair..."
    ssh-keygen -N "" -f pomerium_user_ca_key -C "Pomerium User CA"

    echo "Generating Host keys..."
    ssh-keygen -t ed25519 -f ssh_host_ed25519_key -N ""
    ssh-keygen -t rsa -b 3072 -f ssh_host_rsa_key -N ""
    ssh-keygen -t ecdsa -b 256 -f ssh_host_ecdsa_key -N ""

    echo ""
    echo "✓ SSH keys generated successfully!"
    echo "  All private keys: repository root (for pasting into Pomerium Zero)"
fi

echo ""

# Step 2: Install User CA public key
echo "=================================================="
echo "Step 2: Installing User CA Public Key"
echo "=================================================="
echo ""
echo "The User CA public key needs to be installed in two places:"
echo "  1. Container: openclaw-data/pomerium-ssh/ (for SSH to container)"
echo "  2. Host: /etc/ssh/ (for SSH to host machine as jump box)"
echo ""

# Copy to container mount
echo "Installing User CA public key for container..."
cp pomerium_user_ca_key.pub ./openclaw-data/pomerium-ssh/
echo "✓ Installed in openclaw-data/pomerium-ssh/"

# Install on host machine
echo ""
echo "Installing User CA public key for host machine SSH..."
echo "This allows you to SSH into this host via Pomerium."
echo ""

# Check if key already exists
if [ -f /etc/ssh/pomerium_user_ca_key.pub ]; then
    echo "⚠️  User CA key already exists at /etc/ssh/pomerium_user_ca_key.pub"
    read -p "Do you want to overwrite it? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        echo "Skipping User CA key installation..."
        SKIP_CA_INSTALL=true
    fi
fi

if [ "$SKIP_CA_INSTALL" != "true" ]; then
    sudo cp pomerium_user_ca_key.pub /etc/ssh/pomerium_user_ca_key.pub
    sudo chmod 644 /etc/ssh/pomerium_user_ca_key.pub
    echo "✓ Installed in /etc/ssh/pomerium_user_ca_key.pub"
fi

# Check if already configured in sshd_config
if grep -q "TrustedUserCAKeys /etc/ssh/pomerium_user_ca_key.pub" /etc/ssh/sshd_config 2>/dev/null; then
    echo "✓ SSH daemon already configured to trust Pomerium CA"
else
    echo ""
    echo "⚠️  SSH daemon configuration needed!"
    echo "   This will add the following line to /etc/ssh/sshd_config:"
    echo ""
    echo "   TrustedUserCAKeys /etc/ssh/pomerium_user_ca_key.pub"
    echo ""
    read -p "Do you want to add this now? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "TrustedUserCAKeys /etc/ssh/pomerium_user_ca_key.pub" | sudo tee -a /etc/ssh/sshd_config > /dev/null
        echo "✓ Added to /etc/ssh/sshd_config"

        # Test sshd config before restarting
        echo ""
        echo "Testing SSH daemon configuration..."
        if sudo sshd -t 2>/dev/null; then
            echo "✓ SSH configuration is valid"

            echo ""
            read -p "Restart SSH daemon now? (y/N): " -n 1 -r
            echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                echo "Restarting SSH daemon..."
                if command -v systemctl &> /dev/null; then
                    sudo systemctl restart sshd || sudo systemctl restart ssh
                    echo "✓ SSH daemon restarted"
                elif command -v service &> /dev/null; then
                    sudo service sshd restart || sudo service ssh restart
                    echo "✓ SSH daemon restarted"
                else
                    echo "⚠️  Could not restart SSH daemon automatically."
                    echo "   Please restart it manually: sudo systemctl restart sshd"
                    HOST_SSH_MANUAL=true
                fi
            else
                echo "Skipped SSH daemon restart."
                echo "⚠️  You'll need to restart it later: sudo systemctl restart sshd"
                HOST_SSH_MANUAL=true
            fi
        else
            echo "❌ SSH configuration test failed!"
            echo "   Please check /etc/ssh/sshd_config for errors"
            HOST_SSH_MANUAL=true
        fi
    else
        echo "Skipped automatic configuration."
        echo "You'll need to manually add it and restart SSH daemon later."
        HOST_SSH_MANUAL=true
    fi
fi

echo ""

# Step 3: Restart container
echo "=================================================="
echo "Step 3: Restarting OpenClaw Container"
echo "=================================================="
echo ""

if ! command -v docker-compose &> /dev/null && ! command -v docker &> /dev/null; then
    echo "⚠️  Warning: Docker not found. Skipping container restart."
    echo "   You'll need to restart manually with:"
    echo "   docker-compose restart openclaw-gateway"
else
    echo "Checking if container is running..."
    if docker-compose ps | grep -q openclaw-gateway; then
        echo "Restarting openclaw-gateway container..."
        docker-compose restart openclaw-gateway
        echo "✓ Container restarted"
    else
        echo "Container not running. You'll need to start it with:"
        echo "  docker-compose up -d"
    fi
fi

echo ""

# Step 4: Instructions for Pomerium Zero
echo "=================================================="
echo "Step 4: Configure Pomerium Zero SSH Route"
echo "=================================================="
echo ""
echo "Next, configure your SSH route in Pomerium Zero console:"
echo ""
echo "1. Navigate to Manage → Routes → Create new 'Guided SSH Route'"
echo ""
echo "2. Configure global SSH settings (first time only):"
echo "   - SSH Address: 0.0.0.0:22"
echo "   - SSH Host Keys: Paste contents of these private keys:"
echo "     * ssh_host_ed25519_key"
echo "     * ssh_host_rsa_key"
echo "     * ssh_host_ecdsa_key"
echo "   - SSH User CA Key: Paste contents of:"
echo "     * pomerium_user_ca_key (private key)"
echo ""
echo "3. Configure the route:"
echo "   - Name: openclaw (or your preferred route name)"
echo "   - From URL: ssh://openclaw"
echo "   - To URL: ssh://openclaw-gateway:22"
echo "   - Access Policies: Configure who can connect"
echo ""
echo "Private key contents are displayed below:"
echo ""
echo "=== ssh_host_ed25519_key ==="
cat ssh_host_ed25519_key
echo ""
echo "=== ssh_host_rsa_key ==="
cat ssh_host_rsa_key
echo ""
echo "=== ssh_host_ecdsa_key ==="
cat ssh_host_ecdsa_key
echo ""
echo "=== pomerium_user_ca_key ==="
cat pomerium_user_ca_key
echo ""

# Step 5: Connect and configure OpenClaw
echo "=================================================="
echo "Step 5: Connect and Configure OpenClaw"
echo "=================================================="
echo ""
echo "Once your Pomerium SSH route is configured, connect to the container:"
echo ""
echo "  ssh root@openclaw@YOUR-CLUSTER.pomerium.app"
echo ""
echo "Then run these commands inside the container:"
echo ""
echo "1. Configure OpenClaw authentication:"
echo "   $ openclaw configure"
echo ""
echo "2. Get the gateway token (you'll need this for device pairing):"
echo "   $ openclaw config get gateway.auth.token"
echo ""
echo "3. After attempting to connect from your browser/device, list pending requests:"
echo "   $ openclaw devices list"
echo ""
echo "4. Approve the device request:"
echo "   $ openclaw devices approve <request-id>"
echo ""
echo "   Replace <request-id> with the ID from the 'devices list' output"
echo ""

# Step 6: Security reminder
echo "=================================================="
echo "Security Reminders"
echo "=================================================="
echo ""
echo "⚠️  IMPORTANT:"
echo "  - All SSH private keys are in the repository root (for Pomerium Zero)"
echo "  - These keys are automatically ignored by .gitignore"
echo "  - Only the User CA public key is in openclaw-data/pomerium-ssh/"
echo "  - Keep all private keys secure (they should have 600 permissions)"
echo "  - Change the default gateway auth token in production!"
echo "  - The default token is: changeme-default-token"
echo ""
echo "To set a custom token:"
echo "  Edit: ./openclaw-data/config/.openclaw/openclaw.json"
echo "  Update: gateway.auth.token"
echo "  Then: docker-compose restart openclaw-gateway"
echo ""

if [ "$HOST_SSH_MANUAL" = true ]; then
    echo "=================================================="
    echo "Manual Host SSH Configuration Required"
    echo "=================================================="
    echo ""
    echo "To enable SSH access to the host machine via Pomerium:"
    echo ""
    echo "1. Copy the User CA public key to /etc/ssh/:"
    echo "   sudo cp pomerium_user_ca_key.pub /etc/ssh/pomerium_user_ca_key.pub"
    echo "   sudo chmod 644 /etc/ssh/pomerium_user_ca_key.pub"
    echo ""
    echo "2. Add this line to /etc/ssh/sshd_config:"
    echo "   TrustedUserCAKeys /etc/ssh/pomerium_user_ca_key.pub"
    echo ""
    echo "3. Restart SSH daemon:"
    echo "   sudo systemctl restart sshd"
    echo "   # or"
    echo "   sudo service sshd restart"
    echo ""
fi

echo "=================================================="
echo "Setup Complete!"
echo "=================================================="
echo ""
echo "Next steps:"
echo "1. Configure Pomerium SSH routes with the keys displayed above"
echo "   - Route to host: ssh://your-username@hostname@your-cluster.pomerium.app"
echo "   - Route to container: ssh://openclaw-gateway:22"
echo "2. SSH into the container and run 'openclaw configure'"
echo "3. Approve device pairing requests as they come in"
echo ""
