# AtScale Deploy Action

This GitHub Action automatically provisions an Azure POC environment and deploys AtScale.

## What it does
1. Creates an Azure Resource Group and VM (`Standard_DC2ds_v3`).
2. Configures Static IP locking and Networking.
3. Installs MicroK8s, MetalLB, and Nginx Ingress.
4. Deploys AtScale via Helm.
5. Configures HTTPS Ingress with self-signed certs.
6. Prints the login credentials to the Action log.

## Usage

Create a file in your repository at `.github/workflows/deploy-atscale.yml`:

```yaml
name: Deploy AtScale POC

on: 
  workflow_dispatch:
    inputs:
      client_id:
        description: "Client Name (e.g. acme)"
        required: true
      region:
        description: "Azure Region"
        default: "eastus"

permissions:
  id-token: write
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - name: Checkout Code
        uses: actions/checkout@v4

      - name: Deploy AtScale
        uses: your-github-username/atscale-deploy-action@v1
        with:
          client_id: ${{ inputs.client_id }}
          region: ${{ inputs.region }}
          azure_client_id: ${{ secrets.AZURE_CLIENT_ID }}
          azure_tenant_id: ${{ secrets.AZURE_TENANT_ID }}
          azure_subscription_id: ${{ secrets.AZURE_SUBSCRIPTION_ID }}
          ssh_public_key: ${{ secrets.SSH_PUBLIC_KEY }}
          ssh_private_key: ${{ secrets.SSH_PRIVATE_KEY }}
