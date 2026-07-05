#!/usr/bin/env bash
# ============================================================================
# setup-crostini-lab.sh — v4 (field-tested on real Chromebook hardware)
# Chromebook Crostini (Debian) bootstrap for ops/dev Lentago lab work
#
# Author:  Chris Pitzi (cpitzi)
# Updated: 2026-03-17
#
# Usage:
#   Interactive:      bash setup-crostini-lab.sh
#   Semi-automated:   GH_TOKEN=ghp_xxx bash setup-crostini-lab.sh
#   Fully unattended: GH_TOKEN=ghp_xxx bash setup-crostini-lab.sh
#   From a gist:      curl -sL <gist-url> | GH_TOKEN=ghp_xxx bash
#
# Environment variables (all optional):
#   GH_TOKEN        GitHub personal access token (scopes: repo, read:org)
#                   If set, skips interactive gh auth login entirely.
#   GIT_NAME        Git user.name (default: "Chris Pitzi")
#   GIT_EMAIL       Git user.email (default: "cpitzi@gmail.com")
#   GITHUB_USER     GitHub username for repo cloning (default: "cpitzi")
#   REPOS_DIR       Where to clone repos (default: ~/repos)
#
# IMPORTANT: Run with 'bash', not 'sh'. Debian's sh is dash, not bash.
#            The shebang handles this if you chmod +x and use ./
#
# What this does:
#   1.  System basics & quality-of-life CLI tools
#   2.  Git config (interactive)
#   3.  Python 3 + pip + venv
#   4.  Node.js (LTS via nvm)
#   5.  Go (latest stable)
#   6.  AWS CLI v2 + Granted (account switching via APT)
#   7.  Terraform + tfswitch
#   8.  kubectl + eksctl + Helm
#   9.  Docker CLI + docker-compose (CLI only, no daemon)
#  10.  GitHub CLI (gh) + authenticate
#  11.  Claude Code
#  12.  Misc: jq, yq, tree, bat, ripgrep, fzf, tmux, shellcheck, direnv
#  13.  Shell config (starship prompt, aliases, PATH wiring)
#  14.  Clone all GitHub repos (cpitzi)
#
# Field-tested bugs fixed in this version:
#   - nvm: directory must exist before installer; source AFTER install
#   - nvm: PROFILE=/dev/null to prevent duplicate .bashrc entries
#   - Granted: use APT repo (GitHub tarball URLs are unstable)
#   - tfswitch: installs to ~/bin; PATH must include it before check
#   - Starship: install to ~/.local/bin (Crostini sudo is broken for
#     third-party install scripts); ensure directory exists first
#   - Clone loop: ((count++)) from 0 kills set -e; use || true guard
#   - PATH: ~/.local/bin and ~/bin must be on PATH at script start,
#     not just in .bashrc (chicken-and-egg with tool detection)
# ============================================================================

set -euo pipefail

# --- Config (overridable via environment variables) -------------------------
GITHUB_USER="${GITHUB_USER:-cpitzi}"
REPOS_DIR="${REPOS_DIR:-$HOME/repos}"
GIT_NAME="${GIT_NAME:-Chris Pitzi}"
GIT_EMAIL="${GIT_EMAIL:-cpitzi@gmail.com}"
# GH_TOKEN is read from environment if set; used by gh CLI directly.

# Detect whether stdin is a terminal (interactive) or piped (automated)
INTERACTIVE=false
[[ -t 0 ]] && INTERACTIVE=true

# --- Bootstrap PATH early ---------------------------------------------------
# Tools installed by this script land in these directories. We need them on
# PATH *during* the script run, not just in .bashrc (which hasn't been
# written yet on first run). This is the single biggest lesson from field
# testing: install-time PATH and shell-config-time PATH must agree.
mkdir -p "$HOME/.local/bin" "$HOME/bin"
export PATH="$HOME/.local/bin:$HOME/bin:$HOME/go/bin:/usr/local/go/bin:$PATH"

# --- Colors & helpers -------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC} $*"; }
success() { echo -e "${GREEN}[ OK ]${NC} $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail()    { echo -e "${RED}[FAIL]${NC} $*"; exit 1; }
skip()    { echo -e "${CYAN}[SKIP]${NC} $*"; }

section() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  $*${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

command_exists() { command -v "$1" &>/dev/null; }

# Verify a command exists after install, or bail with a helpful message
require() {
  local cmd="$1"
  local friendly="${2:-$1}"
  if ! command_exists "$cmd"; then
    fail "$friendly failed to install. Check the output above for errors."
  fi
}

TOTAL_STEPS=14

# --- Preflight --------------------------------------------------------------
section "Preflight Checks"

if [[ "$(uname -s)" != "Linux" ]]; then
  fail "This script is for Linux (Crostini/Debian). You're on $(uname -s)."
fi

if [[ -z "${BASH_VERSION:-}" ]]; then
  fail "This script requires bash. Run it with: bash $0"
fi

info "Detected: $(grep PRETTY_NAME /etc/os-release | cut -d= -f2 | tr -d '"')"
info "User: $(whoami) | Home: $HOME"
info "GitHub user: $GITHUB_USER | Repos dir: $REPOS_DIR"
info "Shell: bash $BASH_VERSION"
if [[ -n "${GH_TOKEN:-}" ]]; then
  info "Mode: non-interactive (GH_TOKEN set)"
elif [[ "$INTERACTIVE" == "true" ]]; then
  info "Mode: interactive (terminal detected)"
else
  info "Mode: non-interactive (piped, no GH_TOKEN)"
fi

# --- 1. System update & base packages --------------------------------------
section "1/$TOTAL_STEPS — System Update & Base Packages"

sudo apt-get update -qq
sudo apt-get upgrade -y -qq

BASE_PKGS=(
  build-essential
  curl
  wget
  git
  unzip
  zip
  gnupg
  lsb-release
  ca-certificates
  software-properties-common
  apt-transport-https
  man-db
  less
  openssh-client
  htop
  ncdu
  nano
)

info "Installing base packages..."
sudo apt-get install -y -qq "${BASE_PKGS[@]}"
success "Base packages installed."

# --- 2. Git config ----------------------------------------------------------
section "2/$TOTAL_STEPS — Git Configuration"

if [[ -z "$(git config --global user.name 2>/dev/null || true)" ]]; then
  git config --global user.name "$GIT_NAME"
  info "Set git user.name = $GIT_NAME"
fi

if [[ -z "$(git config --global user.email 2>/dev/null || true)" ]]; then
  git config --global user.email "$GIT_EMAIL"
  info "Set git user.email = $GIT_EMAIL"
fi

git config --global init.defaultBranch main
git config --global pull.rebase true
git config --global push.autoSetupRemote true
git config --global core.editor "nano"
git config --global alias.st "status -sb"
git config --global alias.lg "log --oneline --graph --decorate -20"
git config --global alias.co "checkout"
git config --global alias.br "branch"
git config --global alias.unstage "reset HEAD --"
git config --global alias.amend "commit --amend --no-edit"
git config --global alias.wip "!git add -A && git commit -m 'WIP'"
success "Git configured."

# --- 3. Python 3 + pip + venv -----------------------------------------------
section "3/$TOTAL_STEPS — Python 3 + pip + venv"

sudo apt-get install -y -qq python3 python3-pip python3-venv python3-full
require python3 "Python 3"
success "Python $(python3 --version 2>&1 | awk '{print $2}') ready."

# --- 4. Node.js via nvm -----------------------------------------------------
section "4/$TOTAL_STEPS — Node.js (LTS via nvm)"

export NVM_DIR="$HOME/.nvm"

# [BUG FIX v3] Directory MUST exist before the nvm installer runs.
# The installer checks $NVM_DIR and errors if set but missing.
mkdir -p "$NVM_DIR"

if [[ ! -s "$NVM_DIR/nvm.sh" ]]; then
  info "Installing nvm..."
  # [BUG FIX v3] PROFILE=/dev/null prevents the installer from appending
  # source lines to .bashrc. We manage our own .bashrc block in step 13.
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | \
    PROFILE=/dev/null bash
fi

# [BUG FIX v3] Source nvm AFTER the install, not before.
if [[ -s "$NVM_DIR/nvm.sh" ]]; then
  # shellcheck source=/dev/null
  . "$NVM_DIR/nvm.sh"
else
  fail "nvm installed but nvm.sh not found at $NVM_DIR/nvm.sh. Check network/git."
fi

if ! command_exists node; then
  info "Installing Node.js LTS..."
  nvm install --lts
  nvm alias default 'lts/*'
else
  info "Node already installed, ensuring LTS is default..."
  nvm install --lts --default 2>/dev/null || true
fi

require node "Node.js"
success "Node $(node -v) + npm $(npm -v) ready."

# --- 5. Go ------------------------------------------------------------------
section "5/$TOTAL_STEPS — Go (latest stable)"

GO_VERSION="1.23.6"  # Bump this when new stable drops
GO_INSTALLED="$(go version 2>/dev/null | grep -oP 'go\K[0-9]+\.[0-9]+\.[0-9]+' || echo 'none')"

if [[ "$GO_INSTALLED" != "$GO_VERSION" ]]; then
  info "Installing Go ${GO_VERSION}..."
  curl -fsSL "https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz" -o /tmp/go.tar.gz
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf /tmp/go.tar.gz
  rm /tmp/go.tar.gz
fi

require go "Go"
success "Go $(go version | awk '{print $3}') ready."

# --- 6. AWS CLI v2 + Granted ------------------------------------------------
section "6/$TOTAL_STEPS — AWS CLI v2 + Granted (account switching)"

if ! command_exists aws || [[ "$(aws --version 2>&1)" != *"aws-cli/2"* ]]; then
  info "Installing AWS CLI v2..."
  cd /tmp
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
  unzip -qo awscliv2.zip
  sudo ./aws/install --update
  rm -rf aws awscliv2.zip
  cd ~
fi
require aws "AWS CLI"
success "AWS CLI $(aws --version 2>&1 | awk '{print $1}') ready."

# [BUG FIX v4] Granted: use official APT repo instead of GitHub release
# tarballs. The tarball URLs changed and 404'd during field testing.
# https://docs.commonfate.io/granted/getting-started
if ! command_exists granted; then
  info "Installing Granted via APT..."
  wget -qO- https://apt.releases.commonfate.io/gpg | \
    sudo gpg --dearmor -o /usr/share/keyrings/common-fate-linux.gpg 2>/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/common-fate-linux.gpg] \
    https://apt.releases.commonfate.io stable main" | \
    sudo tee /etc/apt/sources.list.d/common-fate.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq granted
fi

if command_exists granted; then
  success "Granted installed — use 'assume <profile>' to switch AWS accounts."
else
  warn "Granted not available — install manually: https://docs.commonfate.io/granted/getting-started"
fi

# --- 7. Terraform + tfswitch ------------------------------------------------
section "7/$TOTAL_STEPS — Terraform + tfswitch"

if ! command_exists tfswitch; then
  info "Installing tfswitch..."
  curl -fsSL https://raw.githubusercontent.com/warrensbox/terraform-switcher/release/install.sh | sudo bash
fi

if command_exists tfswitch; then
  success "tfswitch ready — run 'tfswitch' in any TF project to auto-select the right version."

  # [BUG FIX v4] tfswitch installs terraform to ~/bin/ by default (not
  # /usr/local/bin). ~/bin is already on PATH from our early bootstrap block.
  if ! command_exists terraform; then
    info "Installing latest Terraform via tfswitch..."
    tfswitch --latest
  fi
else
  warn "tfswitch install failed. Installing Terraform via HashiCorp APT repo instead..."
  wget -qO- https://apt.releases.hashicorp.com/gpg | \
    gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg >/dev/null
  echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] \
    https://apt.releases.hashicorp.com $(lsb_release -cs) main" | \
    sudo tee /etc/apt/sources.list.d/hashicorp.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq terraform
fi

if command_exists terraform; then
  success "Terraform $(terraform version -json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["terraform_version"])' 2>/dev/null || terraform version | head -1) ready."
else
  warn "Terraform not installed — run 'tfswitch' after setup to install."
fi

# ┌──────────────────────────────────────────────────────────────────────┐
# │ TERRAGRUNT — uncomment when you need multi-env DRY Terraform.      │
# │ You'll know when the time comes: it's when you find yourself       │
# │ copy-pasting backend configs between staging/ and production/      │
# │ and hating yourself for it.                                        │
# └──────────────────────────────────────────────────────────────────────┘
# if ! command_exists terragrunt; then
#   info "Installing Terragrunt..."
#   TG_VERSION=$(curl -fsSL https://api.github.com/repos/gruntwork-io/terragrunt/releases/latest | \
#     python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"].lstrip("v"))')
#   sudo wget -q "https://github.com/gruntwork-io/terragrunt/releases/download/v${TG_VERSION}/terragrunt_linux_amd64" \
#     -O /usr/local/bin/terragrunt
#   sudo chmod +x /usr/local/bin/terragrunt
#   success "Terragrunt ${TG_VERSION} ready."
# fi

# --- 8. kubectl + eksctl + Helm ---------------------------------------------
section "8/$TOTAL_STEPS — kubectl + eksctl + Helm"

if ! command_exists kubectl; then
  info "Installing kubectl..."
  KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64/kubectl" \
    -o /tmp/kubectl
  sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm /tmp/kubectl
fi
require kubectl "kubectl"
success "kubectl $(kubectl version --client -o json 2>/dev/null | python3 -c 'import sys,json;print(json.load(sys.stdin)["clientVersion"]["gitVersion"])' 2>/dev/null || echo 'installed') ready."

if ! command_exists eksctl; then
  info "Installing eksctl..."
  PLATFORM="$(uname -s)_amd64"
  curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_${PLATFORM}.tar.gz" | \
    tar xz -C /tmp
  sudo install -m 0755 /tmp/eksctl /usr/local/bin/eksctl
  rm -f /tmp/eksctl
fi
require eksctl "eksctl"
success "eksctl $(eksctl version 2>/dev/null || echo 'installed') ready."

if ! command_exists helm; then
  info "Installing Helm..."
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
require helm "Helm"
success "Helm $(helm version --short 2>/dev/null || echo 'installed') ready."

# --- 9. Docker CLI (no daemon) + docker-compose ------------------------------
section "9/$TOTAL_STEPS — Docker CLI + Compose (CLI only, no daemon)"

if ! command_exists docker; then
  info "Installing Docker CLI (client only)..."
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | \
    sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg 2>/dev/null
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian $(lsb_release -cs) stable" | \
    sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce-cli docker-compose-plugin
fi
require docker "Docker CLI"
success "Docker CLI + Compose plugin ready (no daemon — point DOCKER_HOST at a remote)."

# --- 10. GitHub CLI (gh) ----------------------------------------------------
section "10/$TOTAL_STEPS — GitHub CLI"

if ! command_exists gh; then
  info "Installing GitHub CLI..."
  sudo mkdir -p -m 755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] \
    https://cli.github.com/packages stable main" | \
    sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq gh
fi
require gh "GitHub CLI"
success "gh $(gh --version 2>/dev/null | head -1) ready."

# Ensure gh is authenticated (needed for repo cloning later)
# GH_TOKEN is the standard env var that gh respects natively.
if ! gh auth status &>/dev/null; then
  if [[ -n "${GH_TOKEN:-}" ]]; then
    # Token provided via environment — authenticate non-interactively.
    info "Authenticating GitHub CLI via GH_TOKEN..."
    echo "$GH_TOKEN" | gh auth login --with-token
  else
    # No token — skip. User can run gh auth login manually.
    warn "GitHub CLI is not authenticated."
    info "Run 'gh auth login' after setup to enable repo cloning."
    info "Or re-run with: GH_TOKEN=ghp_xxx bash $0"
  fi
fi

if gh auth status &>/dev/null; then
  success "GitHub CLI authenticated."
  gh auth setup-git
else
  warn "GitHub auth skipped — repo cloning will only work for public repos."
fi

# --- 11. Claude Code --------------------------------------------------------
section "11/$TOTAL_STEPS — Claude Code"

if ! command_exists claude; then
  info "Installing Claude Code..."
  npm install -g @anthropic-ai/claude-code
fi

if command_exists claude; then
  success "Claude Code installed. Run 'claude' to authenticate and get started."
else
  warn "Claude Code install failed. Try manually: npm install -g @anthropic-ai/claude-code"
fi

# --- 12. Quality-of-life CLI tools ------------------------------------------
section "12/$TOTAL_STEPS — Quality-of-Life CLI Tools"

# APT-available tools
QOL_PKGS=(jq tree tmux shellcheck direnv)
sudo apt-get install -y -qq "${QOL_PKGS[@]}"

# bat (called 'batcat' on Debian due to a name conflict)
if ! command_exists bat && ! command_exists batcat; then
  sudo apt-get install -y -qq bat 2>/dev/null || true
fi

# ripgrep
if ! command_exists rg; then
  sudo apt-get install -y -qq ripgrep 2>/dev/null || true
fi

# fzf — clone and install (apt version is often ancient)
if ! command_exists fzf; then
  info "Installing fzf..."
  [[ -d "$HOME/.fzf" ]] && rm -rf "$HOME/.fzf"
  git clone --depth 1 https://github.com/junegunn/fzf.git "$HOME/.fzf"
  "$HOME/.fzf/install" --key-bindings --completion --no-update-rc --no-bash --no-zsh --no-fish
fi

# yq (YAML processor — the Go-based one by Mike Farah)
if ! command_exists yq; then
  info "Installing yq..."
  YQ_VERSION=$(curl -fsSL https://api.github.com/repos/mikefarah/yq/releases/latest | \
    python3 -c 'import sys,json;print(json.load(sys.stdin)["tag_name"])') || true
  if [[ -n "${YQ_VERSION:-}" ]]; then
    sudo wget -q "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_amd64" \
      -O /usr/local/bin/yq
    sudo chmod +x /usr/local/bin/yq
  else
    warn "Could not fetch yq version. Skipping."
  fi
fi

# [BUG FIX v4] Starship: install to ~/.local/bin to avoid Crostini's broken
# sudo for third-party install scripts. The directory was created at the top
# of this script in the PATH bootstrap section.
if ! command_exists starship; then
  info "Installing Starship prompt..."
  curl -fsSL https://starship.rs/install.sh | sh -s -- -y -b "$HOME/.local/bin"
fi

# Report what we got
INSTALLED_QOL=""
for tool in jq yq tree tmux shellcheck direnv fzf rg starship; do
  command_exists "$tool" && INSTALLED_QOL="$INSTALLED_QOL $tool"
done
command_exists batcat && INSTALLED_QOL="$INSTALLED_QOL bat(cat)"
command_exists bat && INSTALLED_QOL="$INSTALLED_QOL bat"

success "CLI tools:${INSTALLED_QOL}"

# --- 13. Shell configuration ------------------------------------------------
section "13/$TOTAL_STEPS — Shell Configuration"

BASHRC="$HOME/.bashrc"
MARKER="# >>> setup-crostini-lab >>>"
END_MARKER="# <<< setup-crostini-lab <<<"

# Remove old block if re-running
if grep -q "$MARKER" "$BASHRC" 2>/dev/null; then
  info "Removing previous config block from .bashrc..."
  sed -i "/$MARKER/,/$END_MARKER/d" "$BASHRC"
fi

info "Appending config to .bashrc..."
cat >> "$BASHRC" << 'BASHRC_BLOCK'
# >>> setup-crostini-lab >>>

# --- PATH ---
export PATH="$HOME/.local/bin:$HOME/bin:$HOME/go/bin:/usr/local/go/bin:$PATH"

# --- nvm ---
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && . "$NVM_DIR/bash_completion"

# --- fzf ---
[ -f "$HOME/.fzf.bash" ] && . "$HOME/.fzf.bash"

# --- direnv ---
command -v direnv &>/dev/null && eval "$(direnv hook bash)"

# --- Starship prompt ---
command -v starship &>/dev/null && eval "$(starship init bash)"

# --- Granted (AWS account switching) ---
# Usage: assume <profile-name>
# Docs:  https://docs.commonfate.io/granted/getting-started
alias assume="source assume"

# --- Aliases: navigation ---
alias ll='ls -alFh --color=auto'
alias la='ls -A --color=auto'
alias l='ls -CF --color=auto'
alias ..='cd ..'
alias ...='cd ../..'
alias repos='cd ~/repos'

# --- Aliases: bat ---
command -v batcat &>/dev/null && alias bat='batcat'

# --- Aliases: kubernetes ---
alias k='kubectl'
alias kgp='kubectl get pods'
alias kgs='kubectl get svc'
alias kgn='kubectl get nodes'
alias kns='kubectl config set-context --current --namespace'
alias kctx='kubectl config use-context'

# --- Aliases: terraform ---
alias tf='terraform'
alias tfi='terraform init'
alias tfp='terraform plan'
alias tfa='terraform apply'
alias tfs='tfswitch'

# --- Aliases: git ---
alias g='git'
alias gs='git status -sb'
alias gd='git diff'
alias gp='git push'
alias gl='git lg'
alias gco='git checkout'
alias gcb='git checkout -b'
alias gwip='git wip'

# --- Aliases: safety nets ---
alias rm='rm -i'
alias cp='cp -i'
alias mv='mv -i'

# --- Docker (point at remote) ---
# export DOCKER_HOST=ssh://user@your-docker-host

# --- AWS defaults (uncomment as needed) ---
# export AWS_PROFILE=default
# export AWS_DEFAULT_REGION=us-east-1

# --- Functions ---

# mkdir + cd in one shot
mkcd() { mkdir -p "$1" && cd "$1"; }

# Quick Python venv setup
venv() {
  local name="${1:-.venv}"
  if [[ ! -d "$name" ]]; then
    python3 -m venv "$name"
    echo "Created venv: $name"
  fi
  # shellcheck disable=SC1091
  source "$name/bin/activate"
  echo "Activated: $name"
}

# Quick look at what's in your repos dir
projects() {
  echo ""
  echo "📂 ~/repos:"
  for dir in ~/repos/*/; do
    [[ -d "$dir/.git" ]] || continue
    local name branch dirty
    name=$(basename "$dir")
    branch=$(git -C "$dir" branch --show-current 2>/dev/null || echo "—")
    dirty=""
    [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]] && dirty=" *"
    printf "  %-30s (%s)%s\n" "$name" "$branch" "$dirty"
  done
  echo ""
}

# Pull all repos at once
pull-all() {
  local ok=0 fail=0
  for dir in ~/repos/*/; do
    if [[ -d "$dir/.git" ]]; then
      local name
      name=$(basename "$dir")
      if git -C "$dir" pull --rebase --quiet 2>/dev/null; then
        echo -e "\033[0;32m  ✓\033[0m $name"
        ((ok++)) || true
      else
        echo -e "\033[1;33m  ⚠ $name (check manually)\033[0m"
        ((fail++)) || true
      fi
    fi
  done
  echo ""
  echo "Pulled: $ok ok, $fail need attention"
}

# <<< setup-crostini-lab <<<
BASHRC_BLOCK

success ".bashrc configured."

# Starship config — Chris's custom prompt
# Design: full absolute path, git always visible in repos, everything else
# appears only when active. Clean and quiet until you need the context.
mkdir -p "$HOME/.config"
cat > "$HOME/.config/starship.toml" << 'STARSHIP_CONF'
# ============================================================================
# Starship prompt — cpitzi
# Full absolute path always visible. Context modules (aws, k8s, terraform,
# etc.) only appear when active. Single line: path, context, then cursor.
# ============================================================================

# The format string controls what shows up and in what order.
# Modules with detect_files/detect_folders only render when relevant.
format = """
$directory\
$git_branch\
$git_status\
$python\
$nodejs\
$golang\
$terraform\
$aws\
$kubernetes\
$cmd_duration\
$character"""

# --- Prompt character -------------------------------------------------------
[character]
success_symbol = "[❯](bold green)"
error_symbol = "[❯](bold red)"

# --- Directory: full absolute path, no truncation ---------------------------
[directory]
truncation_length = 0          # 0 = never truncate
truncate_to_repo = false       # show full path even inside git repos
format = "[$path]($style) "
style = "bold cyan"

# Home directory is still shown as ~ (starship default). To see the raw
# /home/cpitzi path instead, uncomment the next line:
# fish_style_pwd_dir_length = 0

# --- Git: branch name + dirty/staged/ahead/behind indicators ---------------
[git_branch]
symbol = " "
format = "[$symbol$branch(:$remote_branch)]($style) "
style = "bold purple"

[git_status]
format = '([\[$all_status$ahead_behind\]]($style) )'
style = "bold red"
# Individual indicators (these are the defaults, shown here for clarity):
# conflicted = "="
# ahead = "⇡"
# behind = "⇣"
# diverged = "⇕"
# untracked = "?"
# stashed = "$"
# modified = "!"
# staged = "+"
# renamed = "»"
# deleted = "✘"

# --- Python: only shows when venv is active or .py/.python-version found ---
[python]
format = '[${symbol}${pyenv_prefix}(${version} )(\($virtualenv\) )]($style)'
symbol = "🐍 "
style = "yellow"

# --- Node: only shows when package.json or .nvmrc found --------------------
[nodejs]
format = "[$symbol($version )]($style)"
symbol = "⬡ "
style = "bold green"

# --- Go: only shows when go.mod or .go files found -------------------------
[golang]
format = "[$symbol($version )]($style)"
symbol = "🐹 "
style = "bold cyan"

# --- Terraform: only shows when .tf files found ----------------------------
[terraform]
format = "[$symbol$workspace]($style) "
symbol = "💠 "
style = "bold 105"    # purple-ish

# --- AWS: only shows when AWS_PROFILE or AWS_REGION is set -----------------
[aws]
format = '[$symbol($profile )(\($region\) )]($style)'
symbol = "☁️  "
style = "bold 208"    # orange

# --- Kubernetes: only shows when KUBECONFIG is set or ~/.kube/config exists -
[kubernetes]
disabled = false       # starship disables k8s by default; we want it
format = '[$symbol$context( \($namespace\))]($style) '
symbol = "⎈ "
style = "bold blue"

# --- Command duration: only shows for commands > 3 seconds -----------------
[cmd_duration]
min_time = 3_000       # milliseconds
format = "took [$duration](bold yellow) "
show_milliseconds = false

# --- Modules we explicitly DON'T want cluttering the prompt ----------------
[package]
disabled = true        # don't show npm/cargo/etc package versions

[username]
disabled = true        # we know who we are

[hostname]
disabled = true        # we know where we are (it's a Chromebook)
STARSHIP_CONF
success "Starship config written."

# --- 14. Clone all GitHub repos ---------------------------------------------
section "14/$TOTAL_STEPS — Clone All GitHub Repos ($GITHUB_USER)"

mkdir -p "$REPOS_DIR"

# Pre-accept github.com SSH host key to avoid interactive prompt in clone loop
if ! grep -q "github.com" "$HOME/.ssh/known_hosts" 2>/dev/null; then
  mkdir -p "$HOME/.ssh"
  ssh-keyscan -t ed25519 github.com >> "$HOME/.ssh/known_hosts" 2>/dev/null || true
fi

if gh auth status &>/dev/null; then
  info "Fetching repo list for $GITHUB_USER..."

  REPO_LIST=$(gh repo list "$GITHUB_USER" --limit 200 --json name,isPrivate \
    --jq '.[] | "\(.name)\t\(.isPrivate)"' 2>/dev/null) || true

  if [[ -z "${REPO_LIST:-}" ]]; then
    warn "No repos found for $GITHUB_USER (or API rate limited)."
  else
    CLONE_COUNT=0
    SKIP_COUNT=0
    FAIL_COUNT=0

    while IFS=$'\t' read -r REPO_NAME IS_PRIVATE; do
      DEST="$REPOS_DIR/$REPO_NAME"

      if [[ -d "$DEST" ]]; then
        skip "$REPO_NAME (already cloned)"
        # [BUG FIX v4] ((x++)) returns 1 (falsy) when x is 0, which kills
        # set -e. The || true guard prevents this.
        ((SKIP_COUNT++)) || true
      else
        PRIVATE_TAG=""
        [[ "$IS_PRIVATE" == "true" ]] && PRIVATE_TAG=" 🔒"

        # Clone via HTTPS (works with gh auth setup-git, no SSH keys needed)
        HTTPS_URL="https://github.com/${GITHUB_USER}/${REPO_NAME}.git"
        if git clone --quiet "$HTTPS_URL" "$DEST" 2>/dev/null; then
          success "$REPO_NAME${PRIVATE_TAG}"
          ((CLONE_COUNT++)) || true
        else
          warn "Failed to clone $REPO_NAME"
          ((FAIL_COUNT++)) || true
        fi
      fi
    done <<< "$REPO_LIST"

    echo ""
    info "Repos: $CLONE_COUNT cloned, $SKIP_COUNT already present, $FAIL_COUNT failed"
  fi
else
  warn "GitHub CLI not authenticated — skipping repo cloning."
  info "Authenticate later with 'gh auth login', then run:"
  info "  cd ~/repos && gh repo list $GITHUB_USER --limit 200 --json name -q '.[].name' | xargs -I{} gh repo clone $GITHUB_USER/{}"
fi

# ============================================================================
section "🎉 Setup Complete!"
echo ""
echo -e "${GREEN}Everything is installed. Open a new terminal or run:${NC}"
echo ""
echo -e "  ${BOLD}source ~/.bashrc${NC}"
echo ""
echo -e "${YELLOW}Post-install checklist:${NC}"
echo "  • Run 'aws configure' (or 'aws configure sso') to set up AWS creds"
echo "  • Run 'assume <profile>' to switch AWS accounts via Granted"
echo "  • Set DOCKER_HOST in ~/.bashrc if using a remote Docker daemon"
echo "  • Run 'claude' to authenticate Claude Code"
echo "  • Run 'projects' to see your cloned repos at a glance"
echo "  • Run 'pull-all' to git pull every repo in ~/repos/"
echo ""
echo -e "${BLUE}Installed tools summary:${NC}"
echo "  Languages:    Python 3, Node.js (nvm), Go, Bash"
echo "  Cloud/Ops:    AWS CLI v2, Granted, Terraform, tfswitch, kubectl, eksctl, Helm"
echo "  Containers:   Docker CLI + Compose (no daemon)"
echo "  Dev tools:    git, gh, Claude Code, jq, yq, ripgrep, fzf, bat, tmux"
echo "  Shell:        Starship prompt, direnv, shellcheck"
echo "  Your code:    ~/repos/ (all $GITHUB_USER repos)"
echo ""
echo -e "${BOLD}Happy hacking, Chris. 🚀${NC}"
