class AddSourceKindToMarineDocuments < ActiveRecord::Migration[7.1]
  SOURCE_SHAPE_SQL = <<~SQL.squish.freeze
    (source_kind = 'website' AND external_link IS NOT NULL AND product_family_code IS NULL AND primary_catalog = false)
    OR (source_kind = 'product_catalog' AND external_link IS NULL AND product_family_code IS NOT NULL AND primary_catalog = true)
    OR (source_kind = 'sop_document' AND external_link IS NULL AND product_family_code IS NULL AND primary_catalog = false)
  SQL

  def up
    add_source_columns
    # Uploaded sources (product_catalog / sop_document) carry a file instead of a URL.
    change_column_null :marine_documents, :external_link, true
    add_source_indexes
    add_source_constraints
  end

  def down
    remove_check_constraint :marine_documents, name: 'marine_documents_source_shape'
    remove_check_constraint :marine_documents, name: 'marine_documents_source_kind_allowed'
    remove_index :marine_documents, name: 'idx_marine_documents_uniq_primary_catalog_per_family'
    remove_index :marine_documents, name: 'index_marine_documents_on_assistant_id_and_family_code'
    remove_index :marine_documents, name: 'index_marine_documents_on_assistant_id_and_source_kind'
    change_column_null :marine_documents, :external_link, false
    remove_column :marine_documents, :primary_catalog
    remove_column :marine_documents, :product_family_code
    remove_column :marine_documents, :source_kind
  end

  private

  def add_source_columns
    add_column :marine_documents, :source_kind, :string, null: false, default: 'website'
    add_column :marine_documents, :product_family_code, :string
    add_column :marine_documents, :primary_catalog, :boolean, null: false, default: false
  end

  def add_source_indexes
    add_index :marine_documents, [:assistant_id, :source_kind],
              name: 'index_marine_documents_on_assistant_id_and_source_kind'
    add_index :marine_documents, [:assistant_id, :product_family_code],
              name: 'index_marine_documents_on_assistant_id_and_family_code'
    add_index :marine_documents, [:assistant_id, :product_family_code],
              unique: true,
              where: "source_kind = 'product_catalog' AND primary_catalog = true",
              name: 'idx_marine_documents_uniq_primary_catalog_per_family'
  end

  def add_source_constraints
    add_check_constraint :marine_documents,
                         "source_kind IN ('website', 'product_catalog', 'sop_document')",
                         name: 'marine_documents_source_kind_allowed'
    add_check_constraint :marine_documents, SOURCE_SHAPE_SQL, name: 'marine_documents_source_shape'
  end
end
