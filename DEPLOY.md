# Deploy do Redmine (Kamal 2)

Branch `deploy` = `7.0-stable` do upstream + infraestrutura deste servidor + plugin
`redmine_agile`. O código core do Redmine não é alterado.

| Item | Valor |
|---|---|
| Domínio | `redmine.polidosantana.com.br` (SSL automático via kamal-proxy) |
| Imagem | `ghcr.io/diegopolido/redmine` (amd64) |
| Ruby / Redmine | 4.0.6 / 7.0-stable |
| Banco | accessory `db` → container `redmine-db`, `mysql:8.4`, volume `mysql_data` |
| Anexos | volume `redmine_files` → `/rails/files` |
| App | Puma, 1 processo × 3 threads, porta 3000, healthcheck `/login` |

Arquivos de infraestrutura: `Dockerfile`, `.dockerignore`, `config/deploy.yml`,
`config/puma.rb`, `config/database.yml`, `config/configuration.yml`, `Gemfile.local`,
`Gemfile.lock`, `bin/docker-entrypoint`, `bin/kamal`, `bin/migration/`, `.kamal/secrets.example`.

Use sempre `bin/kamal`, nunca um `kamal` global.

## Preparar a máquina local (uma vez)

```sh
bundle config set --local only development   # só o Kamal; dispensa headers do MySQL
bundle install
bin/migration/init_secrets.sh                # cria .kamal/secrets (fora do git), se não existir
export KAMAL_REGISTRY_PASSWORD=ghp_...       # token do GitHub com write:packages
```

**Guarde uma cópia de `.kamal/secrets` no seu gerenciador de senhas.** Se o
`SECRET_KEY_BASE` mudar, todo mundo é deslogado. Se o `MYSQL_ROOT_PASSWORD` se
perder, você perde o acesso root ao banco.

## Checklist do dia da migração

1. **Backup no servidor antigo.** Opcional: pare o nginx antes, para congelar os dados.
   ```sh
   scp bin/migration/backup_old_server.sh usuario@servidor-antigo:/tmp/
   ssh usuario@servidor-antigo 'sudo REDMINE_DIR=/caminho/do/redmine bash /tmp/backup_old_server.sh'
   ```
   O script gera `~/redmine-migration/{redmine.sql.gz,redmine-files.tar.gz,MANIFEST.txt}`.
2. **Trazer o backup e conferir os checksums.**
   ```sh
   mkdir -p tmp/migration
   scp 'usuario@servidor-antigo:~/redmine-migration/*' tmp/migration/
   (cd tmp/migration && sha256sum redmine.sql.gz redmine-files.tar.gz) # compare com MANIFEST.txt
   ```
3. **(Opcional, recomendado) Ensaiar com o backup real**, só com Docker local:
   ```sh
   bin/migration/e2e_local_test.sh tmp/migration/redmine.sql.gz tmp/migration/redmine-files.tar.gz
   ```
4. **Preencher o IP** da VPS em `config/deploy.yml` (aparece uma única vez) e commitar:
   ```sh
   sed -i 's/<<IP_DA_VPS>>/203.0.113.10/' config/deploy.yml
   git commit -am "Set VPS IP"
   ```
5. **Garantir o acesso SSH** como `root` com a sua chave (`ssh root@IP true`) e confirmar
   que o kamal-proxy compartilhado já foi iniciado pelo repo de infraestrutura. Se ele
   ainda não existir, o `kamal setup` sobe um proxy com a configuração padrão.
6. **Primeiro deploy.** Isso faz o build e o push da imagem, sobe o accessory `db` e sobe
   a app com um banco vazio:
   ```sh
   bin/kamal setup
   ```
7. **Restaurar o dump e os anexos.** O script para a app, recria o banco, importa o dump,
   restaura os anexos, roda as migrations do core e dos plugins, limpa as sessões e sobe a
   app de novo:
   ```sh
   bin/migration/restore.sh tmp/migration/redmine.sql.gz tmp/migration/redmine-files.tar.gz
   ```
8. **Testar antes do DNS:**
   ```sh
   curl -skI --resolve redmine.polidosantana.com.br:443:IP https://redmine.polidosantana.com.br/login
   ```
9. **Apontar o DNS:** registro `A` de `redmine.polidosantana.com.br` para o IP novo. O
   certificado Let's Encrypt é emitido na primeira requisição HTTPS depois que o DNS propagar.
10. **Conferir** em `https://redmine.polidosantana.com.br`:
    - login;
    - um issue com anexo antigo (download);
    - o board do Agile;
    - upload de um anexo novo;
    - *Administração → Informações*;
    - *Administração → Configurações → Geral*: "Nome do servidor" e "Protocolo" = `https`.
      Esses valores vêm do banco antigo, por isso vale conferir;
    - *Administração → Configurações → Notificações por e-mail → Enviar um e-mail de teste*,
      se o SMTP estiver configurado.
11. Depois de alguns dias, desligue o servidor antigo.

`restore.sh` é idempotente. Se algo der errado, corrija e rode de novo; ele
recria o banco e substitui os anexos.

## Secrets

Os secrets ficam em `.kamal/secrets`, que está no `.gitignore`. O modelo é
`.kamal/secrets.example`. Cada linha pode ter um valor literal, `$VAR` (lido do ambiente)
ou `$(comando)`, por exemplo a CLI de um gerenciador de senhas.

| Secret | Uso |
|---|---|
| `KAMAL_REGISTRY_PASSWORD` | Token do GitHub com `write:packages` (push/pull no ghcr.io) |
| `SECRET_KEY_BASE` | `secret_key_base` do Rails. **Fixo entre deploys** |
| `MYSQL_ROOT_PASSWORD` | root do accessory `db` |
| `REDMINE_DB_PASSWORD` | usuário `redmine` do MySQL (a app usa este) |
| `MYSQL_PASSWORD` | igual a `REDMINE_DB_PASSWORD`. O container mysql só usa no primeiro boot, para criar o usuário |
| `SMTP_PASSWORD` | senha SMTP (vazio = sem SMTP) |

`MYSQL_ROOT_PASSWORD` e `MYSQL_PASSWORD` só valem no **primeiro** boot do volume
`mysql_data`. Para trocá-los depois, use `ALTER USER` no banco (`bin/kamal dbc`) e
atualize `.kamal/secrets`.

### SMTP

O envio de e-mail fica desligado enquanto `SMTP_ADDRESS` não estiver definido. Para
ligar, descomente o bloco `SMTP_*` em `config/deploy.yml`. O padrão é a porta 587 com
STARTTLS e autenticação `login`. Para TLS implícito na porta 465, use `SMTP_PORT: 465`,
`SMTP_TLS: "true"` e `SMTP_ENABLE_STARTTLS: "false"`. Depois preencha `SMTP_PASSWORD` e
rode `bin/kamal deploy`. O remetente (`From`) é uma configuração do Redmine guardada no
banco: *Administração → Configurações → Notificações por e-mail*.

## Operação

```sh
bin/kamal logs                  # logs da app
bin/kamal console               # rails console
bin/kamal shell                 # bash no container
bin/kamal dbc                   # cliente mysql como root (pede MYSQL_ROOT_PASSWORD)
bin/kamal accessory logs db
```

As migrations (core + plugins) rodam automaticamente a cada boot da app, no
`bin/docker-entrypoint`.

### Compartilhar o banco com outra app

O accessory se chama `db` e o container é `redmine-db`, acessível na rede `kamal` em
`redmine-db:3306` sem nenhuma porta pública. Para outra app usar o mesmo MySQL, crie um
banco e um usuário só para ela:

```sql
CREATE DATABASE outra_app CHARACTER SET utf8mb4;
CREATE USER 'outra_app'@'%' IDENTIFIED BY '...';
GRANT ALL PRIVILEGES ON outra_app.* TO 'outra_app'@'%';
```

Se no futuro o MySQL passar a ser gerenciado pelo repo de infraestrutura, basta mudar
`REDMINE_DB_HOST` em `config/deploy.yml`.

## Atualizar o Redmine (releases do 7.0-stable)

```sh
git checkout deploy
git fetch upstream                    # remote upstream = https://github.com/redmine/redmine
git merge upstream/7.0-stable
bundle lock                           # atualiza Gemfile.lock se o Gemfile mudou
git commit -am "Update Gemfile.lock"  # se houve mudança
bin/migration/e2e_local_test.sh       # opcional: ensaio local (5.0 → 7.0 com dados de exemplo)
bin/kamal deploy
```

Toda a customização está em arquivos que o upstream não tem. O único ponto de conflito
possível é o fim do `.gitignore` (bloco `deploy branch`).

**Plugin redmine_agile:** substitua o diretório `plugins/redmine_agile` pelo conteúdo do
zip novo, rode `bundle lock`, commite e faça o deploy. `redmine:plugins:migrate` roda
sozinho no boot.

**Ruby:** a versão está em `ARG RUBY_VERSION` no `Dockerfile`. Evite 4.0.0–4.0.3, que têm
uma regressão de performance na wiki.

## Política de versão do Kamal

- O Kamal está fixado em `Gemfile.local` (`~> 2.12.0`, grupo `development`, fora da imagem).
- **Todas as apps do servidor precisam usar a mesma versão** do gem `kamal`, porque
  compartilham um único kamal-proxy.
- Para atualizar:
  1. mude a versão em **todos** os repos;
  2. reinicie o kamal-proxy **uma única vez**, a partir do repo de infraestrutura;
  3. faça o deploy das apps.
- Este repo nunca roda `kamal proxy reboot`, `kamal proxy boot_config` nem outras
  configurações globais do proxy.

## Observações

- ImageMagick e Ghostscript não estão na imagem, para mantê-la enxuta. Por isso não há
  miniaturas de imagens/PDF nem exportação do Gantt para PNG. Para ativar, adicione
  `imagemagick ghostscript` ao `apt-get install` do estágio `base` e tire `minimagick` do
  `BUNDLE_WITHOUT`.
- Backups periódicos da VPS nova (volumes `mysql_data` e `redmine_files`) não fazem parte
  deste repo.
