# VHS tape for the README demo animation.
#
# Renders docs/images/demo.gif -- a real, unfaked run of these provisioning
# scripts: create a cloud VM, let cloud-init run combine.sh (health.sh, fqdn.sh,
# k3s-node.sh) on it, then deploy a three-container application onto the
# resulting cluster with the stack utility and reach it over HTTPS with a real
# Let's Encrypt certificate -- and destroy the machine again at the end.
#
# Run it via ./demo/record-demo.sh, which builds the scratch HOME this tape
# assumes, warms the container build cache off camera, and fills in the @@...@@
# placeholders below. Because of those placeholders this file is a template: run
# vhs against the rendered copy the record script writes, not against this file.
#
# Requires: vhs, ttyd, ffmpeg, machine, stack, kubectl, docker, jq, openssl.

Output docs/images/demo.gif

Set Shell bash
Set FontSize 14
Set Width 1100
Set Height 620
Set Padding 18
Set Framerate 20
Set TypingSpeed 20ms
Set Theme "Catppuccin Mocha"

# --- off-camera setup ------------------------------------------------------
# HOME points at a scratch home holding only the demo's machine config, the
# demo ssh key and the registry credentials, so the recording never touches (or
# shows) the real ~/.config/machine -- and so each run gets a fresh session id,
# which keeps the session-scoped `machine list` and `machine destroy` at the end
# looking only at this demo's machine.
#
# The API token, ssh key name, DNS zone, project and registry credentials all
# reach the config file as ${...} environment variable references, so no secret
# is ever on screen even though the config file is.
Hide
Type "cd /tmp/provisioning-demo && export HOME=/tmp/provisioning-demo/home"
Enter
Type "export STACK_REPO_BASE_DIR=/tmp/provisioning-demo/repos"
Enter
Type `PS1='\[\e[38;5;114m\]▸\[\e[0m\] '`
Enter
Type "clear"
Enter
Show

# --- what is about to happen -----------------------------------------------
# The whole demo is configured by this one file. The interesting part is the
# machine type: a script-url pointing at this repository's combine.sh, and a
# script-args list naming the scripts to run on first boot and their arguments.
Type "cat ~/.config/machine/config.yml"
Enter
Wait+Line@60s /^▸$/
Sleep 5s

Type "clear"
Enter

# --- create the machine ----------------------------------------------------
# ~45s of real work: create the VM, wait for its IP address, add the DNS A
# record for it, and hand cloud-init the user data that fetches combine.sh and
# runs the three scripts. --progress animates the otherwise silent wait for the
# IP address.
Type "# nothing exists yet. create a machine and let it provision itself:"
Enter
Sleep 1500ms

Type "machine create --name @@MACHINE_NAME@@ --type k3s-host --wait-for-ip --progress"
Enter
Wait+Line@600s /^▸$/
Sleep 2s

# machine-status comes from the provider's API -- the VM exists. cloud-init-status
# is served by health.sh on the machine itself, so it reads UNKNOWN until that
# endpoint is up, and only reports UP once combine.sh has run every script it
# was given.
Type "# the machine exists; cloud-init is now running combine.sh on it:"
Enter
Sleep 1s

Type "machine status"
Enter
Wait+Line@120s /^▸$/
Sleep 3s

# --- wait for provisioning (off camera) ------------------------------------
# Installing k3s, cert-manager and their images on a cold node takes several
# minutes of no output at all, which is not worth filming. The `clear` is
# inside the hidden block on purpose: Hide stops recording frames but the
# terminal still holds the line that was typed, so without it the wait loop
# would sit on screen for the rest of the recording.
#
# ERROR ends the loop as well as UP: health.sh reports a failed provision, and
# waiting out the timeout on a take that is already ruined helps nobody. The
# status shown on camera next is whichever one it reached.
Hide
Type "until machine status | grep -qE 'cloud-init-status=(UP|ERROR)'; do sleep 10; done"
Enter
Wait+Line@1800s /^▸$/
Type "clear"
Enter
Show

Type "# ...a few minutes later (the wait is cut from the recording):"
Enter
Sleep 1500ms

Type "machine status"
Enter
Wait+Line@120s /^▸$/
Sleep 3s

Type "clear"
Enter

# --- it really is a Kubernetes cluster -------------------------------------
# k3s writes a kubeconfig naming the local address; the machine's FQDN is in the
# API server's certificate because k3s-node.sh adds $MACHINE_FQDN as a tls-san,
# so substituting it yields a kubeconfig that works from here.
Type "# fqdn.sh gave it a name, k3s-node.sh gave it a cluster. take the kubeconfig:"
Enter
Sleep 1s

Type `ssh -i ~/.ssh/demo-key -o StrictHostKeyChecking=accept-new \`
Enter
Type `  demo@@@FQDN@@ 'sudo cat /etc/rancher/k3s/k3s.yaml' \`
Enter
Type `  | sed 's/127.0.0.1/@@FQDN@@/g' > kubeconfig`
Enter
Wait+Line@300s /^▸$/
Sleep 1s

Type "export KUBECONFIG=/tmp/provisioning-demo/kubeconfig"
Enter
Wait+Line@60s /^▸$/

# Every kubectl call below is also an assertion that the tls-san went in: they
# reach the API server by the machine's hostname, over the public internet.
Type "kubectl get nodes"
Enter
Wait+Line@300s /^▸$/
Sleep 2500ms

# cert-manager, traefik and the rest were installed by k3s-node.sh, not by
# anything on this laptop.
Type "kubectl get pods -A"
Enter
Wait+Line@120s /^▸$/
Sleep 4s

Type "clear"
Enter

# The pieces an application needs to be reachable with TLS: the Gateway that
# workloads attach HTTPRoutes to, and the issuers that get them certificates.
Type "kubectl get gateway -n kube-system"
Enter
Wait+Line@120s /^▸$/
Sleep 2500ms

Type "kubectl get clusterissuer"
Enter
Wait+Line@120s /^▸$/
Sleep 3s

Type "clear"
Enter

# --- off camera: build the application's images and push them --------------
# Building three containers and uploading them to a registry is the stack
# utility's business, not this repository's, and it is minutes of build log. The
# record script builds the images before recording starts; this pushes them to
# the registry the cluster has credentials for, so the `push-images` below is a
# real push with nothing left to upload.
Hide
Type "stack init --stack todo --output warm.yml --deploy-to k8s --kube-config /tmp/provisioning-demo/kubeconfig --image-registry @@IMAGE_REGISTRY@@ --http-proxy-fqdn @@FQDN@@"
Enter
Wait+Line@300s /^▸$/
Type "stack deploy --cluster warm --spec-file warm.yml --deployment-dir /tmp/provisioning-demo/warm"
Enter
Wait+Line@300s /^▸$/
Type "stack manage --dir /tmp/provisioning-demo/warm push-images"
Enter
Wait+Line@1800s /^▸$/
Type "rm -rf /tmp/provisioning-demo/warm warm.yml"
Enter
Wait+Line@60s /^▸$/
Type "clear"
Enter
Show

# --- deploy an application onto it -----------------------------------------
# A three-container application -- React front end, API, PostgreSQL -- from
# https://github.com/bozemanpass/example-todo-list, deployed with the stack
# utility from this laptop. Nothing about the machine is special-cased here: the
# spec names the cluster's kubeconfig, a registry, and the hostname to serve on.
Type "# the machine is ready. deploy a three-container app onto it:"
Enter
Sleep 1500ms

Type `stack init --stack todo --output todo.yml --deploy-to k8s \`
Enter
Type `  --kube-config /tmp/provisioning-demo/kubeconfig \`
Enter
Type `  --image-registry @@IMAGE_REGISTRY@@ --http-proxy-fqdn @@FQDN@@ \`
Enter
Type `  --config REACT_APP_API_URL=https://@@FQDN@@/api/todos`
Enter
Wait+Line@300s /^▸$/
Sleep 1500ms

Type "mkdir -p ~/deployments"
Enter
Wait+Line@60s /^▸$/

Type `stack deploy --cluster todo --spec-file todo.yml \`
Enter
Type `  --deployment-dir ~/deployments/todo`
Enter
Wait+Line@300s /^▸$/
Sleep 1500ms

# The cluster cannot see this laptop's image cache, so the images go to the
# registry named in the spec -- the one k3s-node.sh configured containerd with
# credentials for, so no imagePullSecrets are involved.
Type "stack manage --dir ~/deployments/todo push-images"
Enter
Wait+Line@1800s /^▸$/
Sleep 1500ms

Type "clear"
Enter

Type "stack manage --dir ~/deployments/todo start"
Enter
Wait+Line@900s /^▸$/
Sleep 2500ms

# Off camera: the pods have to pull and start, the Gateway has to route to them
# and cert-manager has to complete the ACME HTTP-01 exchange for this hostname.
# That is a minute or two of real waiting and no output.
Hide
Type `for i in $(seq 240); do curl -sf -o /dev/null https://@@FQDN@@/api/todos && break; sleep 5; done`
Enter
Wait+Line@1500s /^▸$/
Type "clear"
Enter
Show

# --- what that produced on the machine -------------------------------------
# Ordinary Kubernetes objects in a namespace named for the deployment: nothing a
# kubectl user would find surprising, all of it removed again by `stack manage
# stop` -- or, in a moment, by destroying the machine.
Type "kubectl -n todo get pods,svc,httproute"
Enter
Wait+Line@300s /^▸$/
Sleep 4s

Type "clear"
Enter

# --- and it works, over HTTPS, from outside the cluster --------------------
# No -k: curl verifying the chain is itself the proof that the certificate is
# real and publicly trusted. cert-manager obtained it minutes ago, for a
# hostname that did not exist when this recording started.
Type `curl -s -o /dev/null -w "front end HTTPS %{http_code}\n" https://@@FQDN@@`
Enter
Wait+Line@120s /^▸$/
Sleep 1500ms

Type `echo | openssl s_client -connect @@FQDN@@:443 2>/dev/null | openssl x509 -noout -issuer`
Enter
Wait+Line@120s /^▸$/
Sleep 2500ms

# The id comes back from the PostgreSQL container, so a successful round trip
# proves the whole application, not merely that a proxy answered.
Type `curl -s -X POST https://@@FQDN@@/api/todos \`
Enter
Type `  -H 'Content-Type: application/json' \`
Enter
Type `  -d '{"title":"Provisioned from nothing"}' | jq -c '{id, title, completed}'`
Enter
Wait+Line@120s /^▸$/
Sleep 2500ms

Type `curl -s https://@@FQDN@@/api/todos | jq -c '.[] | {id, title, completed}'`
Enter
Wait+Line@120s /^▸$/
Sleep 3s

Type "clear"
Enter

# --- back to nothing -------------------------------------------------------
# `list -q` prints ids only, so this session's machines pipe straight into
# destroy. The DNS record created at the start goes with it.
Type "# and back to nothing:"
Enter
Sleep 1s

Type "machine destroy --delete-dns $(machine list -q)"
Enter
# The confirmation prompt leaves the cursor on an empty input line, so match the
# screen rather than the last line.
Wait+Screen@120s /Type YES/
Sleep 1500ms
Type "YES"
Enter
Wait+Line@600s /^▸$/
Sleep 2s

Type "machine list"
Enter
Wait+Line@120s /^▸$/
Sleep 4s
