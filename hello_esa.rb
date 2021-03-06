require 'esa'
require 'json'
require 'pp'
require 'pry'
require './lib/retryable'
require './lib/collection'

access_token = ARGV[0]
team_name = ARGV[1]
file_path = ARGV[2]
image_files_path = ARGV[3]

client = Esa::Client.new(
  access_token: access_token,
  current_team: team_name, # 移行先のチーム名(サブドメイン)
)

class Importer
  include Retryable
  attr_accessor :client, :items

  def initialize(client, file_path, image_files_path)
    @client = client
    @items  = JSON.parse(File.read(file_path))
    @images = {}
    File.open(image_files_path) do |f|
      while line = f.gets
        mappings = line.split(' ')
        @images[mappings[0]] = mappings[1]
      end
    end
  end

  def import!(dry_run: true, start_index: 0)
    items['articles'].sort_by{ |item| item['updated_at'] }.each.with_index do |item, index|
      next unless index >= start_index

      @images.keys.each do |image|
        if item['body'].match(image)
          item['body'] = item['body'].gsub(image, @images[image])
        end
      end

      params = {
        name:     item['title'],
        category: "Imported/Qiita",
        tags:     item['tags'].map{ |tag| tag['name'].gsub('/', '-') }.map{ |name| "qiita-#{name}" },
        body_md:  <<-BODY_MD,
Original URL: #{item['url']}
Original created at:#{item['created_at']}
Qiita:Team:User:#{item['user']['id']}

#{item['body']}
BODY_MD
        wip:      false,
        message:  '[skip notice] Imported from Qiita',
        user:     'esa_bot',  # 記事作成者上書き: owner権限が必要
      }

      if dry_run
        puts "***** index: #{index} *****"
        pp params
        puts
        next
      end

      puts "[#{Time.now}] index[#{index}] #{item['title']} => "

      response_body = wrap_response { client.create_post(params) }
      puts "imported: #{item['url']} to #{response_body['url']}"

      item['comments'].each do |comment|
        comment_params = {
          body_md:  <<-BODY_MD,
#{comment['body']}

<div style="color: #ccc">Original created at:#{comment['created_at']}</div>
<div style="color: #ccc">Qiita:Team:User:#{comment['user']['id']}</div>
BODY_MD
          user: 'esa_bot'
        }
        wrap_response { client.create_comment(response_body['number'], comment_params) }
      end
    end
  end
end

importer = Importer.new(client, file_path, image_files_path)
# dry_run: trueで確認後に dry_run: falseで実際にimportを実行
importer.import!(dry_run: false, start_index: 0)
