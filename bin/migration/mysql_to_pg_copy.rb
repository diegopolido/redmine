# frozen_string_literal: true

# Copies every row from the MySQL source database (`mysql_src` entry in
# database.yml) into the PostgreSQL `production` database, whose schema was
# created beforehand by Redmine's own migrations at the same versions.
#
# Run by bin/migration/convert_mysql_to_pg.sh inside a Redmine 5.0 container:
#   RAILS_ENV=production bin/rails runner /scripts/mysql_to_pg_copy.rb
#
# Guarantees (aborts otherwise):
#   * every source table/column exists in the destination;
#   * schema_migrations is identical on both sides;
#   * row counts match table by table.

BATCH = 1000
SKIP = %w[schema_migrations ar_internal_metadata].freeze

class SourceRecord < ActiveRecord::Base
  self.abstract_class = true
end
SourceRecord.establish_connection(:mysql_src)

src = SourceRecord.connection
dst = ActiveRecord::Base.connection
abort "destination is not PostgreSQL" unless dst.adapter_name =~ /postg/i

def fail!(msg)
  warn "ERROR: #{msg}"
  exit 1
end

# --- Schema checks ----------------------------------------------------------
src_versions = src.select_values("SELECT version FROM schema_migrations").map(&:to_s).sort
dst_versions = dst.select_values("SELECT version FROM schema_migrations").map(&:to_s).sort
if src_versions != dst_versions
  fail! "schema_migrations differ.\n  only in MySQL: #{(src_versions - dst_versions).inspect}\n" \
        "  only in PostgreSQL: #{(dst_versions - src_versions).inspect}"
end

src_tables = src.tables.sort - SKIP
missing = src_tables - dst.tables
fail! "tables missing in PostgreSQL: #{missing.join(', ')}" if missing.any?

plan = src_tables.map do |table|
  src_cols = src.columns(table).map(&:name)
  dst_cols = dst.columns(table).index_by(&:name)
  extra = src_cols - dst_cols.keys
  fail! "#{table}: columns missing in PostgreSQL: #{extra.join(', ')}" if extra.any?
  [table, src_cols, dst_cols]
end
puts "Schema OK: #{plan.size} tables, #{src_versions.size} migrations match."

# --- Copy -------------------------------------------------------------------
boolean = ActiveModel::Type::Boolean.new
stripped_nul = Hash.new(0)

cast = lambda do |table, column, value|
  return nil if value.nil?

  case column.type
  when :boolean then boolean.cast(value)
  when :binary  then dst.escape_bytea(value.to_s)
  when :string, :text
    v = value.to_s
    if v.include?("\u0000")
      stripped_nul["#{table}.#{column.name}"] += 1
      v = v.delete("\u0000") # PostgreSQL text cannot store NUL bytes
    end
    v
  else value
  end
end

dst.transaction do
  # Disable FK/trigger checks during the bulk load (superuser in the local
  # throwaway container).
  dst.execute("SET LOCAL session_replication_role = replica")

  plan.each do |table, cols, dst_cols|
    qt = dst.quote_table_name(table)
    dst.execute("TRUNCATE #{qt} CASCADE") # migrations seed some rows
    col_list = cols.map { |c| dst.quote_column_name(c) }.join(', ')
    src_cols_sql = cols.map { |c| src.quote_column_name(c) }.join(', ')
    has_id = cols.include?('id')

    copied = 0
    last_id = nil
    loop do
      sql = "SELECT #{src_cols_sql} FROM #{src.quote_table_name(table)}"
      if has_id
        sql += " WHERE id > #{last_id.to_i}" if last_id
        sql += " ORDER BY id LIMIT #{BATCH}"
      end
      rows = src.select_rows(sql)
      break if rows.empty?

      values = rows.map do |row|
        '(' + row.each_with_index.map { |v, i| dst.quote(cast.call(table, dst_cols[cols[i]], v)) }.join(', ') + ')'
      end
      values.each_slice(BATCH) do |slice|
        dst.execute("INSERT INTO #{qt} (#{col_list}) VALUES #{slice.join(', ')}")
      end
      copied += rows.size
      break unless has_id

      last_id = rows.last[cols.index('id')]
    end

    src_count = src.select_value("SELECT COUNT(*) FROM #{src.quote_table_name(table)}").to_i
    dst_count = dst.select_value("SELECT COUNT(*) FROM #{qt}").to_i
    fail! "#{table}: row count mismatch (MySQL #{src_count}, PostgreSQL #{dst_count})" if src_count != dst_count

    dst.reset_pk_sequence!(table) if has_id
    printf("  %-40s %8d rows\n", table, dst_count)
  end
end

stripped_nul.each { |col, n| warn "WARNING: removed NUL bytes from #{n} value(s) in #{col}" }
total = plan.sum { |t, _, _| dst.select_value("SELECT COUNT(*) FROM #{dst.quote_table_name(t)}").to_i }
puts "Copy OK: #{total} rows in #{plan.size} tables; row counts match; sequences reset."
