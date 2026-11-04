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
`Gemfile.lock`, `bin/docker-entrypoint`, `bin/kamal`, `bin/env-secret`, `bin/migration/`,
`.kamal/secrets`, `.kamal/hooks/pre-connect`, `.env.production.example`.

Use sempre `bin/kamal`, nunca um `kamal` global.

## Preparar a máquina local (uma vez)

```sh
bundle config set --local only development   # só o Kamal; dispensa headers do MySQL
bundle install
bin/migration/init_secrets.sh                # cria .env.production com senhas aleatórias, se não existir
$EDITOR .env.production                      # token do GitHub + chave SMTP da Brevo
```

**Guarde uma cópia do `.env.production` no seu gerenciador de senhas.** Se o
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

Os valores ficam **só na sua máquina**, no arquivo `.env.production` na raiz do repo. Ele está no
`.gitignore` e no `.dockerignore`, e o modelo é `.env.production.example`. O Kamal envia esses
valores para o servidor durante o deploy, como variáveis de ambiente dos containers.

- `.kamal/secrets` é versionado e **não contém valores**. Cada linha chama
  `bin/env-secret NOME`, que procura primeiro uma variável de ambiente com esse nome e
  depois o `.env.production`. Nunca coloque valores literais nesse arquivo.
- `.kamal/hooks/pre-connect` aborta qualquer comando do Kamal se faltar um secret
  obrigatório. Sem esse hook, o Kamal faria o deploy com o valor vazio. O hook também
  aborta se houver risco de vazamento:
  - um valor de secret ou algo com cara de token (`ghp_`, `github_pat_`, `xsmtpsib-`…) no
    `.env.production.example`;
  - uma linha do `.kamal/secrets` que não seja `NOME=$(bin/env-secret NOME)`;
  - o `.env.production` rastreado pelo git.

  Essa verificação só roda quando você usa o `bin/kamal`, não no `git commit`. Confira o
  `git status` antes de commitar.
- Para conferir (cuidado, isso imprime os valores): `bin/kamal secrets print`.

| Secret | Uso |
|---|---|
| `KAMAL_REGISTRY_PASSWORD` | Token do GitHub com `write:packages` (push/pull no ghcr.io) |
| `SECRET_KEY_BASE` | `secret_key_base` do Rails. **Fixo entre deploys** |
| `MYSQL_ROOT_PASSWORD` | root do accessory `db` |
| `REDMINE_DB_PASSWORD` | usuário `redmine` do MySQL (a app usa este) |
| `MYSQL_PASSWORD` | igual a `REDMINE_DB_PASSWORD`. O container mysql só usa no primeiro boot, para criar o usuário |
| `SMTP_ADDRESS` | `smtp-relay.brevo.com` (vazio = sem envio de e-mail) |
| `SMTP_PORT` | `587` |
| `SMTP_USERNAME` | login SMTP da Brevo (algo como `xxxxxx@smtp-brevo.com`) |
| `SMTP_PASSWORD` | chave SMTP da Brevo (`xsmtpsib-...`, não é a chave de API `xkeysib-...`) |
| `MAILER_FROM` | remetente, ex. `'Redmine <redmine@polidosantana.com.br>'` |

As variáveis SMTP e `MAILER_FROM` têm os mesmos nomes usados nas outras apps.

`MYSQL_ROOT_PASSWORD` e `MYSQL_PASSWORD` só valem no **primeiro** boot do volume
`mysql_data`. Para trocá-los depois, use `ALTER USER` no banco (`bin/kamal dbc`) e
atualize o `.env.production`.

### SMTP (Brevo)

`SMTP_ADDRESS`, `SMTP_PORT`, `SMTP_USERNAME`, `SMTP_PASSWORD` e `MAILER_FROM` ficam no
`.env.production`. O login e a chave SMTP estão em *Brevo → SMTP & API → aba SMTP*. O
`config/deploy.yml` define STARTTLS, autenticação `login` e o HELO `polidosantana.com.br`.

- **Remetente:** a cada boot, a task `deploy:apply_settings` (`lib/tasks/deploy.rake`)
  grava `MAILER_FROM` na configuração *Administração → Configurações → Notificações por
  e-mail → "E-mail de envio"*. Por isso, mudanças feitas nessa tela são sobrescritas no
  próximo deploy; altere o `.env.production`. Com `MAILER_FROM` vazio, vale o que estiver
  no banco.
- O endereço precisa ser um remetente verificado na Brevo (*Senders, Domains & Dedicated
  IPs*), de preferência com o domínio `polidosantana.com.br` autenticado (DKIM e DMARC no
  DNS). Se você já fez isso para as outras apps, nada muda.
- Para desligar o envio, deixe `SMTP_ADDRESS` vazio. O hook deixa de exigir as credenciais.

**Testar o envio localmente.** O script usa a imagem de produção, um MySQL temporário e
o mesmo método do botão "Enviar um e-mail de teste" da Administração:

```sh
bin/test-email --mailpit voce@exemplo.com   # SMTP falso local, nada sai da máquina
                                            # (KEEP=1 mantém a UI em http://localhost:8025)
bin/test-email voce@exemplo.com             # envio real pela Brevo, com os valores do .env.production
```

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
