class CreateUsers < ActiveRecord::Migration[7.2]
  def change
    create_table :users do |t|
      t.string :line_user_id       # LINEのID（これで誰かを見分けます）
      t.string :name               # LINEの名前
      t.string :profile_image_url  # アイコン画像のURL
      
      t.timestamps                 # 登録日時
    end
  end
end