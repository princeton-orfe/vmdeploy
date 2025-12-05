# SMTP Configuration for Failure Notifications

The Azure VM deployment includes email notifications for service failures. You need to configure an SMTP relay for outbound email.

## Option 1: Azure Communication Services (Recommended)

Azure Communication Services provides email without needing an external provider.

```bash
# Install Azure CLI extension
az extension add --name communication

# Create Communication Services resource
az communication create \
    --name myapp-comm \
    --resource-group <your-resource-group> \
    --data-location unitedstates

# Create email service (follow Azure portal for domain verification)
```

Then configure postfix:

```bash
# /etc/postfix/main.cf
relayhost = [smtp.azurecomm.net]:587
smtp_sasl_auth_enable = yes
smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd
smtp_sasl_security_options = noanonymous
smtp_tls_security_level = encrypt
```

## Option 2: SendGrid (Free Tier Available)

1. Create SendGrid account in Azure Portal (Marketplace > SendGrid)
2. Generate API key in SendGrid dashboard

```bash
# Create credentials file
sudo cat > /etc/postfix/sasl_passwd << 'EOF'
[smtp.sendgrid.net]:587 apikey:YOUR_SENDGRID_API_KEY
EOF

# Secure and hash the file
sudo chmod 600 /etc/postfix/sasl_passwd
sudo postmap /etc/postfix/sasl_passwd

# Update postfix config
sudo postconf -e "relayhost = [smtp.sendgrid.net]:587"
sudo postconf -e "smtp_sasl_auth_enable = yes"
sudo postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
sudo postconf -e "smtp_sasl_security_options = noanonymous"
sudo postconf -e "smtp_tls_security_level = encrypt"

# Restart postfix
sudo systemctl restart postfix
```

## Option 3: Microsoft 365 / Outlook

If you have M365, you can relay through smtp.office365.com:

```bash
sudo cat > /etc/postfix/sasl_passwd << 'EOF'
[smtp.office365.com]:587 your-email@domain.com:your-password
EOF

sudo chmod 600 /etc/postfix/sasl_passwd
sudo postmap /etc/postfix/sasl_passwd

sudo postconf -e "relayhost = [smtp.office365.com]:587"
sudo postconf -e "smtp_sasl_auth_enable = yes"
sudo postconf -e "smtp_sasl_password_maps = hash:/etc/postfix/sasl_passwd"
sudo postconf -e "smtp_sasl_security_options = noanonymous"
sudo postconf -e "smtp_tls_security_level = encrypt"
sudo postconf -e "smtp_tls_CAfile = /etc/ssl/certs/ca-certificates.crt"

sudo systemctl restart postfix
```

## Testing Email

```bash
# Send test email
echo "Test email from Azure VM" | mail -s "VM Test" your-email@example.com

# Check mail queue
mailq

# Check logs
sudo tail -f /var/log/mail.log
```

## Troubleshooting

```bash
# Check postfix status
sudo systemctl status postfix

# View mail log
sudo journalctl -u postfix -f

# Test SMTP connection
openssl s_client -starttls smtp -connect smtp.sendgrid.net:587
```
