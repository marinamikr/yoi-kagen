class CreateFriendsMemberships < ActiveRecord::Migration[7.2]
  def change
    create_table :friends do |t|
      t.string :group_id      # LINEのグループID
      t.string :line_user_id  # ユーザーのLINE ID
      t.timestamps
    end
  end
end