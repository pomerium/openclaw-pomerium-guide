# SSH Troubleshooting Session - 2026-02-03

## Problem Summary

SSH access via Pomerium to the openclaw gateway container is failing with "Permission Denied" after commit `6434d12` (feat: add user claw to openclaw gateway container).

### Error Message
```
ssh claw@clawgate@fantastic-fox-1234.pomerium.app -p 2200
Please sign in with auth0 to continue
https://authenticate.fantastic-fox-1234.pomerium.app/.pomerium/sign_in?user_code=...
Received disconnect from 107.159.13.157 port 2200:2: Permission Denied
Disconnected from 107.159.13.157 port 2200
```

### Working Before
- SSH worked for root user prior to commit `6434d12`
- Using the same Pomerium route configuration
- Authenticated as: `ntaylor@pomerium.com` (google-oauth2|110679203791094235151)

## Key Findings

### Pomerium Logs Analysis
From `docker logs mrclaw-pomerium-1`:
```json
{"level":"info","protocol":"ssh","message":"successfully authenticated"}
{"level":"info","user":"google-oauth2|110679203791094235151","email":"ntaylor@pomerium.com","allow":true,"allow-why-true":["email-ok"],"message":"authorize check"}
{"level":"error","message":"ssh: stream 14922899983596533751 closing with error: Permission Denied"}
```

**Key insight**: Pomerium authenticates and authorizes successfully, but then the connection fails with "Permission Denied".

### SSH Server Status
- sshd IS running in the container
- Port 22 is listening
- TrustedUserCAKeys is correctly configured
- Pomerium User CA key is valid and accessible

### No SSH Connection Logs
- Even with sshd in debug mode, no connection attempts appear in the openclaw container logs
- This suggests the error happens at the Pomerium level, not the SSH server level

## Configuration Comparison

### Before Commit 6434d12 (WORKING)
```dockerfile
# No claw user - everything ran as root
WORKDIR /root

# SSH Config
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
RUN echo "TrustedUserCAKeys /var/lib/pomerium/pomerium_user_ca_key.pub" >> /etc/ssh/sshd_config

# Volumes
- ./openclaw-data/config:/root
- ./openclaw-data/workspace:/root/workspace
```

### After Commit 6434d12 (BROKEN)
```dockerfile
# Added claw user
RUN useradd -m -s /bin/bash claw
WORKDIR /home/claw

# SSH Config - initially set PermitRootLogin no
RUN sed -i 's/#PermitRootLogin prohibit-password/PermitRootLogin no/' /etc/ssh/sshd_config
RUN echo "TrustedUserCAKeys /var/lib/pomerium/pomerium_user_ca_key.pub" >> /etc/ssh/sshd_config

# Volumes
- ./openclaw-data/config:/home/claw
- ./openclaw-data/workspace:/home/claw/workspace
```

## Attempts Made

### Attempt 1: Enable Root Login
Changed `PermitRootLogin no` to `PermitRootLogin yes`
- **Result**: Still failed for both root and claw users

### Attempt 2: Fix File Permissions
Added to entrypoint.sh:
```bash
chown -R claw:claw /home/claw
chown -R root:root /root
chmod 700 /root
```
- **Result**: Permissions fixed but SSH still failed

### Attempt 3: Add AuthorizedPrincipals
Added to SSH config:
```
AuthorizedPrincipalsFile /etc/ssh/auth_principals/%u
```
With `*` wildcard for both root and claw users
- **Rationale**: Allow any Pomerium certificate principal to log in as these users
- **Result**: Still failed
- **Note**: Pomerium docs don't mention this being required

### Attempt 4: Try Username Matching Email
Tried: `ssh ntaylor@clawgate@fantastic-fox-1234.pomerium.app -p 2200`
- **Rationale**: Match email prefix (ntaylor@pomerium.com)
- **Result**: Still failed with same error

### Attempt 5: Revert to Original Working Config
Reverted SSH configuration to exactly match pre-6434d12:
- `PermitRootLogin prohibit-password`
- Only `TrustedUserCAKeys` configured
- Removed AuthorizedPrincipals
- **Result**: Still failed (even though this exact config worked before)

## Verified Components

✅ **User CA Key**
- Present at `/var/lib/pomerium/pomerium_user_ca_key.pub`
- Valid ED25519 key: `SHA256:ZmT9JccByQZp/wltn+SFOWhwVXElkQsAlDVG9Q7XfaQ`
- Properly mounted from host to container (read-only)
- Correct permissions (644, root:root)

✅ **Users Exist**
```
root:x:0:0:root:/root:/bin/bash
claw:x:1001:1001::/home/claw:/bin/bash
```

✅ **Network Connectivity**
- All containers on same Docker network (172.19.0.x/16)
- openclaw-gateway at 172.19.0.3
- pomerium at 172.19.0.2
- Port 22 exposed on openclaw-gateway

✅ **Pomerium Policy**
```
ALLOW
AND
  Criteria: Email
  Operator: Is
  Email: ntaylor@pomerium.com
OR
  Criteria: Email
  Operator: Is
  Email: nick@nickyt.co
```
- No visible SSH username restrictions
- Authorization succeeds (allow:true)

## Unanswered Questions

1. **Pomerium Route Configuration**: What is the exact "To" URL in the Pomerium Zero route?
   - Expected: `ssh://openclaw-gateway:22`
   - Need to verify this is correct

2. **Hidden SSH Policy**: Are there SSH-specific criteria in the Pomerium route that weren't visible in the policy screenshot?
   - `ssh_username`
   - `ssh_username_matches_email`
   - `ssh_username_matches_claim`

3. **Why Did It Break?**: If we reverted to the exact working SSH config, why does it still fail?
   - Possible: Pomerium route configuration changed
   - Possible: Something about having the claw user affects Pomerium's connection

4. **Certificate Principal**: What principal is Pomerium actually putting in the SSH certificate?
   - Is it the email? `ntaylor@pomerium.com`
   - Is it the user ID? `google-oauth2|110679203791094235151`
   - Is it something else?

## Next Steps to Try

1. **Check Pomerium Route Configuration**
   - Verify the "To" URL is correct
   - Look for any SSH-specific policy criteria
   - Check if there's a TCP route vs SSH route setting

2. **Test Direct SSH (Bypass Pomerium)**
   - Temporarily expose port 22 on host
   - Try SSH directly to verify SSH server works
   - This isolates whether it's SSH or Pomerium issue

3. **Enable More Verbose Logging**
   - Increase Pomerium log level
   - Capture full SSH handshake details
   - See what certificate Pomerium is actually issuing

4. **Compare with Working Setup**
   - If possible, check out commit before 6434d12
   - Capture exact working state
   - See if Pomerium logs differ when it works

5. **Check Pomerium Documentation**
   - Review SSH route requirements
   - Check if there are known issues with containerized SSH targets
   - Look for examples with similar setups

## Files Modified During Troubleshooting

- `openclaw/Dockerfile` - Multiple SSH configuration attempts
- `openclaw/entrypoint.sh` - Added ownership fixes
- Both files should be reset before trying new approach

## References

- [Pomerium Zero SSH Guide](https://www.pomerium.com/docs/guides/zero-ssh)
- [Pomerium Native SSH Access](https://www.pomerium.com/docs/capabilities/native-ssh-access)
- Commit 6434d12: "feat: add user claw to openclaw gateway container"
