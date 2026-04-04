#!/bin/bash
# 01-security.sh — SSH hardening, firewall, fail2ban, auto-updates, email
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/common.sh"
load_config

log_section "Security Hardening"

# --- SSH Hardening ---

log "Configuring SSH..."
render_template "$TEMPLATES_DIR/sshd_config" /etc/ssh/sshd_config
log_ok "SSH config deployed (port $SSH_PORT, key-only, no root login)"
log "sshd restart deferred until user SSH keys are in place (02-users.sh)"

# --- Firewall (UFW) ---

log "Configuring firewall..."
if ! command -v ufw &>/dev/null; then
    apt_install ufw
fi

# Only reset if UFW isn't active yet; otherwise just ensure rules exist
if ! ufw status | grep -q "Status: active"; then
    ufw --force reset >> "$LOG_FILE" 2>&1
    ufw default deny incoming >> "$LOG_FILE" 2>&1
    ufw default allow outgoing >> "$LOG_FILE" 2>&1
fi
ufw allow "$SSH_PORT/tcp" comment "SSH" >> "$LOG_FILE" 2>&1

if [ -n "${RDP_ALLOWED_IP:-}" ]; then
    ufw allow from "$RDP_ALLOWED_IP" to any port 3389 proto tcp comment "RDP from allowed IP" >> "$LOG_FILE" 2>&1
    log_ok "RDP allowed from $RDP_ALLOWED_IP"
fi

ufw --force enable >> "$LOG_FILE" 2>&1
log_ok "UFW enabled (deny incoming, allow SSH on port $SSH_PORT)"

# --- Fail2ban ---

log "Configuring fail2ban..."
apt_install fail2ban
render_template "$TEMPLATES_DIR/jail.local" /etc/fail2ban/jail.local
systemctl enable fail2ban >> "$LOG_FILE" 2>&1
systemctl restart fail2ban >> "$LOG_FILE" 2>&1
log_ok "fail2ban configured (SSH on port $SSH_PORT, 6 retries, 5-min ban)"

# --- Automatic Updates ---

log "Configuring automatic updates..."
apt_install unattended-upgrades apt-listchanges

cp "$TEMPLATES_DIR/50unattended-upgrades" /etc/apt/apt.conf.d/50unattended-upgrades
cp "$TEMPLATES_DIR/20auto-upgrades" /etc/apt/apt.conf.d/20auto-upgrades

# Add email config if Resend is configured
if [ -n "${RESEND_API_KEY:-}" ] && [ -n "${ALERT_EMAIL:-}" ]; then
    sed -i "s|// MAIL_CONFIG_PLACEHOLDER|Unattended-Upgrade::Mail \"${ALERT_EMAIL}\";\nUnattended-Upgrade::MailReport \"only-on-error\";|" \
        /etc/apt/apt.conf.d/50unattended-upgrades
fi

systemctl enable unattended-upgrades >> "$LOG_FILE" 2>&1
log_ok "Unattended-upgrades configured (security + regular, reboot at 03:00)"

# --- Email via Postfix + Resend (optional) ---

if [ -n "${RESEND_API_KEY:-}" ]; then
    log "Configuring email alerts via Resend..."
    apt_install postfix libsasl2-modules

    # Configure Postfix as send-only relay through Resend
    postconf -e "relayhost = [smtp.resend.com]:587"
    postconf -e "smtp_sasl_auth_enable = yes"
    postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
    postconf -e "smtp_sasl_security_options = noanonymous"
    postconf -e "smtp_tls_security_level = encrypt"
    postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"
    postconf -e "inet_interfaces = loopback-only"
    postconf -e "mydestination = "

    if [ -n "${RESEND_FROM_ADDRESS:-}" ]; then
        postconf -e "myhostname = $(echo "$RESEND_FROM_ADDRESS" | cut -d@ -f2)"
    fi

    # SMTP credentials
    echo "[smtp.resend.com]:587 resend:${RESEND_API_KEY}" > /etc/postfix/sasl_passwd
    chmod 600 /etc/postfix/sasl_passwd
    postmap /etc/postfix/sasl_passwd

    systemctl enable postfix >> "$LOG_FILE" 2>&1
    systemctl restart postfix >> "$LOG_FILE" 2>&1
    log_ok "Postfix configured as send-only relay via Resend"

    # Configure fail2ban to send email (only if not already configured)
    if ! grep -q "destemail" /etc/fail2ban/jail.local; then
        cat >> /etc/fail2ban/jail.local << EOF

[DEFAULT]
destemail = ${ALERT_EMAIL}
sender = ${RESEND_FROM_ADDRESS}
mta = mail
action = %(action_mwl)s
EOF
    fi
    systemctl restart fail2ban >> "$LOG_FILE" 2>&1
    log_ok "Fail2ban email alerts configured"
else
    log_skip "Email alerts (no Resend API key provided)"
fi

# --- Prometheus Node Exporter ---

if systemctl is-active prometheus-node-exporter &>/dev/null; then
    log_skip "Node exporter already running"
else
    log "Installing Prometheus node_exporter..."
    apt_install prometheus-node-exporter
    # Bind to localhost only — no external exposure unless user opens firewall
    mkdir -p /etc/default
    echo 'ARGS="--web.listen-address=127.0.0.1:9100"' > /etc/default/prometheus-node-exporter
    systemctl enable prometheus-node-exporter >> "$LOG_FILE" 2>&1
    systemctl restart prometheus-node-exporter >> "$LOG_FILE" 2>&1
    log_ok "Node exporter installed (localhost:9100, ready for Grafana Cloud or Prometheus)"
fi

log_ok "Security hardening complete"
