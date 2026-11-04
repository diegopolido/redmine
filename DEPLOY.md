# Deploy do Redmine (Kamal 2)

Branch `deploy` = `7.0-stable` do upstream + infraestrutura deste servidor + plugin
`redmine_agile`. O código core do Redmine não é alterado.

| Item | Valor |
|---|---|
| Domínio | `redmine.polidosantana.com.br` (SSL automático via kamal-proxy) |
| Imagem | `ghcr.io/diegopolido/redmine` (amd64) |
| Ruby / Redmine | 4.0.6 / 7.0-stable |
| Banco | Postgres **próprio desta app**: accessory `db` → container `redmine-db`, `postgres:18`, volume `redmine_pgdata`, limite de 512 MB, sem porta pública |
| Anexos | volume `redmine_files` → `/rails/files` |
| App | Puma, 1 processo × 3 threads (pool = 3), porta 3000, healthcheck `/login` |

Arquivos de infraestrutura:
- **Imagem e app:** `Dockerfile`, `.dockerignore`, `bin/docker-entrypoint`, `config/puma.rb`,
  `config/database.yml`, `config/configuration.yml`, `lib/tasks/deploy.rake`.
- **Kamal e secrets:** `config/deploy.yml`, `bin/kamal`, `bin/env-secret`, `.kamal/secrets`,
  `.kamal/hooks/pre-connect`, `.env.production.example`.
- **Gems:** `Gemfile.local`, `Gemfile.lock`.
- **Scripts:** `bin/backup_now.sh`, `bin/test-email`, `bin/migration/`.

Use sempre `bin/kamal`, nunca um `kamal` global.

## Preparar a máquina local (uma vez)

```sh
bundle config set --local only development   # só o Kamal; dispensa headers nativos
bundle install
bin/migration/init_secrets.sh                # cria .env.production com senhas aleatórias, se não existir
$EDITOR .env.production                      # token do GitHub + chave SMTP da Brevo
```

**Guarde uma cópia do `.env.production` no seu gerenciador de senhas.** Se o
`SECRET_KEY_BASE` mudar, todo mundo é deslogado.

## Checklist do dia da migração (servidor antigo MySQL → VPS nova Postgres)

O servidor antigo é `deploy@95.217.214.85`. Lá rodam Redmine 5.0.5 e redmine_agile 1.6.5
sobre MySQL 8.0, em `/home/deploy/www/redmine/redmine-5.0-stable`. Não é preciso `sudo`.

1. **Backup no servidor antigo.** Opcional: pare o nginx antes, para congelar os dados.
   ```sh
   scp bin/migration/backup_old_server.sh deploy@95.217.214.85:/tmp/
   ssh deploy@95.217.214.85 'bash /tmp/backup_old_server.sh'
   ```
   O script gera `~/redmine-migration/{redmine.sql.gz,redmine-files.tar.gz,MANIFEST.txt}`.
2. **Trazer o backup e conferir os checksums:**
   ```sh
   mkdir -p tmp/migration
   scp 'deploy@95.217.214.85:~/redmine-migration/*' tmp/migration/
   (cd tmp/migration && sha256sum -c <(sed -n 's/^  //p' MANIFEST.txt | grep -E '\.(gz)$'))
   ```
3. **Converter MySQL → Postgres, na sua máquina.** Só usa Docker; nada vai para servidor
   nenhum:
   ```sh
   bin/migration/convert_mysql_to_pg.sh tmp/migration/redmine.sql.gz   # → tmp/migration/redmine.pgdump
   ```
   O script usa a versão do Redmine registrada no `MANIFEST.txt`. Ele recria o schema no
   Postgres com as migrations do próprio Redmine e para com erro se alguma tabela, coluna,
   migration ou contagem de linhas não bater.
4. **Ensaiar localmente** a restauração e o upgrade até a 7.0:
   ```sh
   bin/migration/e2e_local_test.sh tmp/migration/redmine.sql.gz tmp/migration/redmine-files.tar.gz
   ```
5. **Preencher o IP** da VPS em `config/deploy.yml` (aparece uma única vez), commitar e
   fazer o push:
   ```sh
   sed -i 's/<<IP_DA_VPS>>/203.0.113.10/' config/deploy.yml
   git commit -am "Set VPS IP" && git push
   ```
6. **Conferir o acesso SSH** como `root` com a sua chave (`ssh root@IP true`). Se o
   kamal-proxy ainda não existir no servidor, o `kamal setup` sobe um com a configuração
   padrão.
7. **Primeiro deploy.** Faz o build e o push da imagem, sobe o Postgres (`db`) e sobe a app
   com um banco vazio:
   ```sh
   bin/kamal setup
   ```
8. **Restaurar.** O script para a app, recria o banco, roda o `pg_restore`, restaura os
   anexos, roda as migrations 5.0 → 7.0 (core e plugins), limpa as sessões e sobe a app
   de novo:
   ```sh
   bin/migration/restore.sh tmp/migration/redmine.pgdump tmp/migration/redmine-files.tar.gz
   ```
9. **Testar antes do DNS:**
   ```sh
   curl -skI --resolve redmine.polidosantana.com.br:443:IP https://redmine.polidosantana.com.br/login
   ```
10. **Apontar o DNS:** registro `A` de `redmine.polidosantana.com.br` para o IP novo. O
    certificado Let's Encrypt é emitido na primeira requisição HTTPS depois que o DNS
    propagar.
11. **Conferir** em `https://redmine.polidosantana.com.br`:
    - login;
    - um issue com anexo antigo (download);
    - o board do Agile;
    - upload de um anexo novo;
    - *Administração → Informações*, que deve mostrar PostgreSQL;
    - *Administração → Configurações → Geral*: "Nome do servidor" e "Protocolo" = `https`.
      Esses valores vêm do banco antigo, por isso vale conferir;
    - *Administração → Configurações → Notificações por e-mail → Enviar um e-mail de teste*.
12. **Fazer o primeiro backup** (`bin/backup_now.sh`) e, depois de alguns dias, desligar o
    servidor antigo.

Os scripts são idempotentes. Se algo der errado, corrija e rode de novo: o `restore.sh`
recria o banco e substitui os anexos.

## Mover o Redmine para outro servidor (no futuro)

Cada app tem o próprio Postgres, então o Redmine se move sozinho, sem conversão:

```sh
bin/backup_now.sh                                     # do servidor atual → ~/backups/redmine/<data>/
sed -i 's/IP_ANTIGO/IP_NOVO/' config/deploy.yml && git commit -am "Move to new server"
bin/kamal setup                                       # no servidor novo: imagem + Postgres + app vazia
bin/migration/restore.sh ~/backups/redmine/<data>/redmine.pgdump ~/backups/redmine/<data>/redmine-files.tar.gz
# conferir com curl --resolve, apontar o DNS, conferir de novo
```

Depois de conferir, remova a app e o banco do servidor antigo, a partir de um checkout
que ainda aponte para o IP antigo:
`bin/kamal remove` e `bin/kamal accessory remove db`.

O caminho backup → restore em outro ambiente faz parte do ensaio local, na etapa E do
`e2e_local_test.sh`.

## Backups manuais

```sh
bin/backup_now.sh [diretório]   # padrão: ~/backups/redmine/<UTC>/
```

O script baixa para a sua máquina `redmine.pgdump` (`pg_dump -Fc`),
`redmine-files.tar.gz` (o volume de anexos) e `MANIFEST.txt` (contagens e sha256). Nada
fica no servidor. Para restaurar, use o `restore.sh`, como na seção anterior. Não há
backup automático; guarde as cópias fora da máquina local.

## Secrets

Os valores ficam **só na sua máquina**, no `.env.production`. Ele está no `.gitignore` e
no `.dockerignore`, e o modelo é `.env.production.example`. Durante o deploy, o Kamal
envia esses valores para os containers como variáveis de ambiente.

- `.kamal/secrets` é versionado e **não contém valores**. Cada linha chama
  `bin/env-secret NOME`, que procura primeiro uma variável de ambiente com esse nome e
  depois o `.env.production`.
- `.kamal/hooks/pre-connect` aborta qualquer comando do Kamal quando falta um secret
  obrigatório. Ele também aborta se houver risco de vazamento:
  - um valor de secret ou algo com cara de token (`ghp_`, `xsmtpsib-`…) no
    `.env.production.example`;
  - uma linha do `.kamal/secrets` que não seja uma chamada a `bin/env-secret`;
  - o `.env.production` rastreado pelo git.

  Essa verificação só roda no `bin/kamal`, não no `git commit`. Confira o `git status`
  antes de commitar.
- Para conferir (cuidado, imprime os valores): `bin/kamal secrets print`.

| Secret | Uso |
|---|---|
| `KAMAL_REGISTRY_PASSWORD` | Token classic do GitHub com `write:packages`, o mesmo para todas as apps |
| `SECRET_KEY_BASE` | `secret_key_base` do Rails. **Fixo entre deploys** |
| `REDMINE_DB_PASSWORD` | Senha do usuário `redmine` do Postgres. Também é enviada como `POSTGRES_PASSWORD` ao container do banco |
| `SMTP_ADDRESS` | `smtp-relay.brevo.com` (vazio = sem envio de e-mail) |
| `SMTP_PORT` | `587` |
| `SMTP_USERNAME` | Login SMTP da Brevo (`xxxxxx@smtp-brevo.com`) |
| `SMTP_PASSWORD` | Chave SMTP da Brevo (`xsmtpsib-...`, não é a chave de API `xkeysib-...`) |
| `MAILER_FROM` | Remetente, ex. `'Redmine <redmine@polidosantana.com.br>'` |

O `POSTGRES_PASSWORD` só vale no **primeiro** boot do volume `redmine_pgdata`. Para trocar
a senha depois, faça os dois passos e depois `bin/kamal deploy`:
1. no banco: `bin/kamal dbc` e `ALTER USER redmine PASSWORD '...';`
2. o mesmo valor no `.env.production`.

### SMTP (Brevo)

As variáveis SMTP e `MAILER_FROM` ficam no `.env.production`, com os mesmos nomes das
outras apps. O `config/deploy.yml` define STARTTLS, autenticação `login` e o HELO
`polidosantana.com.br`.

- **Remetente:** a cada boot, a task `deploy:apply_settings` grava `MAILER_FROM` em
  *Administração → Configurações → Notificações por e-mail → "E-mail de envio"*. Mudanças
  feitas nessa tela são sobrescritas no próximo deploy.
- O remetente precisa estar verificado na Brevo, de preferência com o domínio autenticado
  (DKIM e DMARC).
- **Desligar o envio:** deixe `SMTP_ADDRESS` vazio.
- **Testar localmente:**
  ```sh
  bin/test-email --mailpit voce@exemplo.com   # SMTP falso local (KEEP=1 → UI em http://localhost:8025)
  bin/test-email voce@exemplo.com             # envio real pela Brevo
  ```

## Operação

```sh
bin/kamal logs                  # logs da app
bin/kamal console               # rails console
bin/kamal shell                 # bash no container
bin/kamal dbc                   # psql no banco redmine
bin/kamal accessory logs db
```

As migrations (core + plugins) rodam automaticamente a cada boot da app, no
`bin/docker-entrypoint`.

**Postgres:** o limite de memória (`options.memory`) e o tuning (`cmd`) ficam no
accessory `db` do `config/deploy.yml`:
- `shared_buffers=128MB`, `work_mem=4MB`, `max_connections=20`;
- dimensionados para 512 MB e um único processo Puma com 3 threads.

Depois de mudar esses valores, rode `bin/kamal accessory reboot db`. Isso derruba o banco
por alguns segundos.

## Atualizar o Redmine (releases do 7.0-stable)

```sh
git checkout deploy
git fetch upstream                    # remote upstream = https://github.com/redmine/redmine
git merge upstream/7.0-stable
bundle lock                           # atualiza Gemfile.lock se o Gemfile mudou
git commit -am "Update Gemfile.lock"  # se houve mudança
bin/migration/e2e_local_test.sh       # opcional: ensaio local completo
bin/kamal deploy
```

Toda a customização está em arquivos que o upstream não tem. O único ponto de conflito
possível é o fim do `.gitignore` (bloco `deploy branch`).

**Plugin redmine_agile:** substitua `plugins/redmine_agile` pelo conteúdo do zip novo,
rode `bundle lock`, commite e faça o deploy. `redmine:plugins:migrate` roda sozinho no boot.

**Ruby:** a versão está em `ARG RUBY_VERSION` no `Dockerfile`. Evite 4.0.0–4.0.3, que têm
uma regressão de performance na wiki.

**Postgres (troca de major, ex. 18 → 19):** não basta trocar a imagem, porque o volume
guarda o formato da major antiga. Faça como numa mudança de servidor:
1. `bin/backup_now.sh`;
2. troque a imagem no `deploy.yml`;
3. `bin/kamal accessory remove db`;
4. `bin/kamal accessory boot db`;
5. `restore.sh`.

## Política de versão do Kamal

- O Kamal está fixado em `Gemfile.local` (`~> 2.12.0`, grupo `development`, fora da imagem).
- **Todas as apps do servidor precisam usar a mesma versão**, porque compartilham um único
  kamal-proxy.
- Para atualizar:
  1. mude a versão em **todos** os repos;
  2. reinicie o kamal-proxy **uma única vez, manualmente**, de qualquer um dos repos,
     com `bin/kamal proxy reboot`, sabendo que isso afeta **todas** as apps do servidor
     por alguns segundos;
  3. faça o deploy das apps.
- Os scripts deste repo nunca rodam `kamal proxy reboot` nem `kamal proxy boot_config`.
  Configurações globais do proxy não ficam aqui.

## Observações

- ImageMagick e Ghostscript não estão na imagem, para mantê-la enxuta. Por isso não há
  miniaturas de imagens/PDF nem exportação do Gantt para PNG. Para ativar, adicione
  `imagemagick ghostscript` ao `apt-get install` do estágio `base` e tire `minimagick` do
  `BUNDLE_WITHOUT`.
- A conversão MySQL → Postgres usa um Redmine 5.0.5 temporário. Nele, `concurrent-ruby` e
  `builder` são fixados em versões antigas por causa de incompatibilidades do Rails 6.1. Isso
  não afeta a imagem de produção.
