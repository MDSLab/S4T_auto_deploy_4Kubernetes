# Deployment Configurazioni Generate

Questa cartella contiene due approcci pronti:

1. Cloud-Init standalone che lancia direttamente `ops/setup-all.sh`
2. Terraform (OpenStack) + Ansible per provisioning e configurazione separati

## 1) Cloud-Init standalone

File: `cloud-init/user-data.yaml`

Uso tipico:
- passare il file come user-data alla creazione VM
- la VM clona il repository in `/opt/unified-deploy`
- esegue `ops/setup-all.sh`
- salva log in `/var/log/s4t-setup.log`
- crea marker in `/var/lib/s4t-setup.done`

## 2) Terraform + Ansible

### Terraform (OpenStack)

Directory: `terraform-openstack/`

Passi:

```bash
cd deploy/terraform-openstack
cp terraform.tfvars.example terraform.tfvars
# modifica i valori nel file terraform.tfvars
terraform init
terraform plan
terraform apply
```

File principali:
- `main.tf`: crea la VM OpenStack
- `cloud-init.yaml`: bootstrap minimo della VM
- `variables.tf`: variabili input
- `outputs.tf`: output deployment

### Ansible

Directory: `ansible/`

Passi:

```bash
cd deploy/ansible
cp inventory.ini.example inventory.ini
# modifica host/IP e chiave SSH
ansible-playbook -i inventory.ini playbook.yml
```

Il playbook:
- installa prerequisiti minimi
- clona/aggiorna il repo
- lancia `ops/setup-all.sh`
- evita riesecuzioni grazie al marker
