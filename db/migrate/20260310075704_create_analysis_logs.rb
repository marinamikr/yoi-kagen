class CreateAnalysisLogs < ActiveRecord::Migration[6.1]
  def change
    create_table :analysis_logs do |t|
      t.string  :line_user_id   # 送ってきた人のLINE ID
      t.text    :original_text  # 酔っ払いの元の文章
      t.text    :sober_text     # シラフ翻訳された文章
      t.integer :yoi_score      # 酔っ払い度（0-100）
      
      t.timestamps              # 作成日時
    end
  end
end