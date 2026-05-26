#!/usr/bin/env bash
# ============================================================
# setup-oci-auth.sh
# Gera chave API, configura ~/.oci/config e cria os tfvars
# Executa uma vez após criar conta OCI
# ============================================================

set -euo pipefail

OCI_DIR="$HOME/.oci"
KEY_FILE="$OCI_DIR/oci_api_key.pem"
PUB_FILE="$OCI_DIR/oci_api_key_public.pem"
CONFIG_FILE="$OCI_DIR/config"

echo "=== SRE Lab — Configuração OCI Authentication ==="
echo ""

# 1. Pega dados do usuário
read -p "Tenancy OCID (ocid1.tenancy.oc1..): " TENANCY_OCID
read -p "User OCID    (ocid1.user.oc1..):    " USER_OCID
REGION="sa-saopaulo-1"

echo ""
echo "Região: $REGION"
echo ""

# 2. Gera par de chaves RSA 2048
echo "[1/4] Gerando par de chaves RSA 2048..."
mkdir -p "$OCI_DIR"
chmod 700 "$OCI_DIR"

openssl genrsa -out "$KEY_FILE" 2048 2>/dev/null
openssl rsa -pubout -in "$KEY_FILE" -out "$PUB_FILE" 2>/dev/null
chmod 600 "$KEY_FILE"

echo "      Chave privada: $KEY_FILE"
echo "      Chave pública: $PUB_FILE"

# 3. Calcula fingerprint
echo "[2/4] Calculando fingerprint..."
FINGERPRINT=$(openssl rsa -pubout -outform DER -in "$KEY_FILE" 2>/dev/null | openssl md5 -c | awk '{print $2}')
echo "      Fingerprint: $FINGERPRINT"

# 4. Cria ~/.oci/config
echo "[3/4] Criando ~/.oci/config..."
cat > "$CONFIG_FILE" <<EOF
[DEFAULT]
user=$USER_OCID
fingerprint=$FINGERPRINT
key_file=$KEY_FILE
tenancy=$TENANCY_OCID
region=$REGION
EOF
chmod 600 "$CONFIG_FILE"

# 5. Cria tfvars nos dois módulos
echo "[4/4] Criando terraform.tfvars..."

for DIR in 00-foundation 01-oke; do
  cat > "$(dirname "$0")/$DIR/terraform.tfvars" <<EOF
tenancy_ocid     = "$TENANCY_OCID"
user_ocid        = "$USER_OCID"
fingerprint      = "$FINGERPRINT"
private_key_path = "$KEY_FILE"
region           = "$REGION"
compartment_ocid = "$TENANCY_OCID"
EOF
done

# Para 01-oke adiciona placeholders das subnets (preenchidos depois do apply do 00-foundation)
cat >> "$(dirname "$0")/01-oke/terraform.tfvars" <<EOF

# Preencha com os outputs do 00-foundation após o apply:
vcn_id            = ""
public_subnet_id  = ""
private_subnet_id = ""
EOF

echo ""
echo "========================================================"
echo "PRÓXIMO PASSO OBRIGATÓRIO:"
echo ""
echo "Adicione a chave pública na OCI Console:"
echo "  1. Acesse: Identity & Security → Users → seu usuário"
echo "  2. Clique em 'API Keys' → 'Add API Key'"
echo "  3. Escolha 'Paste public key'"
echo "  4. Cole o conteúdo abaixo:"
echo "========================================================"
echo ""
cat "$PUB_FILE"
echo ""
echo "========================================================"
echo "Após adicionar a chave, teste a autenticação:"
echo "  oci iam user get --user-id $USER_OCID"
echo "========================================================"
