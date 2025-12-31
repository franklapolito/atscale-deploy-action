# AtScale Deploy Action

This GitHub Action automatically provisions an Azure POC environment and deploys AtScale.

## What it does
1. Creates an Azure Resource Group and VM (`Standard_DC2ds_v3`).
2. Configures Static IP locking and Networking.
3. Installs MicroK8s, MetalLB, and Nginx Ingress.
4. Deploys AtScale via Helm.
5. Configures HTTPS Ingress with self-signed certs.
6. Prints the login credentials to the Action log.

```mermaid
flowchart LR
    %% Styles
    classDef user fill:#f3f6fc,stroke:#747775,stroke-width:1px,color:#1e1e1e;
    classDef internal fill:#e8f0fe,stroke:#747775,stroke-width:1px,color:#1e1e1e;
    
    subgraph User["User Experience (Declarative)"]
        direction TB
        UI[/"uses: atscale-inc/deploy-action
        with:
          client_id: 'acme'
          region: 'eastus'"/]:::user
    end

    subgraph BlackBox["Internal Execution (Imperative)"]
        direction TB
        Step1[1. Input Parsing]:::internal
        Step2[2. VM Provisioning]:::internal
        Step3[3. Security Bootstrap]:::internal
        Step4[4. Helm Deploy]:::internal
        
        Step1 --> Step2 --> Step3 --> Step4
    end

    UI -.->|Abstraction| BlackBox

    %% Layout hints
    linkStyle default stroke:#0b57d0,stroke-width:2px;
```


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

