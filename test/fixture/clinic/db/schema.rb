ActiveRecord::Schema[8.1].define(version: 1) do
  create_table "appointments", force: :cascade do |t|
    t.string "status", null: false, default: "booked"
    t.datetime "starts_at", null: false
    t.string "patient_token", null: false
    t.timestamps
  end
end
