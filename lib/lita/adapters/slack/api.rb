require 'faraday'

require 'lita/adapters/slack/team_data'
require 'lita/adapters/slack/slack_im'
require 'lita/adapters/slack/slack_user'
require 'lita/adapters/slack/slack_source'
require 'lita/adapters/slack/slack_channel'

module Lita
  module Adapters
    class Slack < Adapter
      # @api private
      class API
        def initialize(config, stubs = nil)
          @config = config
          @stubs = stubs
          @post_message_config = {}
          @post_message_config[:parse] = config.parse unless config.parse.nil?
          @post_message_config[:link_names] = config.link_names ? 1 : 0 unless config.link_names.nil?
          @post_message_config[:unfurl_links] = config.unfurl_links unless config.unfurl_links.nil?
          @post_message_config[:unfurl_media] = config.unfurl_media unless config.unfurl_media.nil?
        end

        def im_open(user_id)
          response_data = call_api("conversations.open", user: user_id)

          SlackIM.new(response_data["channel"]["id"], user_id)
        end

        def channels_info(channel_id)
          call_api("channels.info", channel: channel_id)
        end

        def users_list
          call_api('users.list')
        end

        def channels_list(params: {})
          conversations_list(types: ["public_channel"], params: params)
        end

        def groups_list(params: {})
          response = conversations_list(types: ["private_channel"], params: params)
          response['groups'] = response['channels']
          response
        end

        def mpim_list(params: {})
          response = conversations_list(types: ["mpim"], params: params)
          response['groups'] = response['channels']
          response
        end

        def im_list(params: {})
          response = conversations_list(types: ["im"], params: params)
          response['ims'] = response['channels']
          response
        end

        def conversations_list(types: ["public_channel"], params: {})
          params.merge!({
            types: types.join(',')
          })
          call_paginated_api(method: 'conversations.list', params: params, result_field: 'channels')
        end

        def call_paginated_api(method:, params:, result_field:)
          result = call_api(
            method,
            params
          )

          next_cursor = fetch_cursor(result)
          old_cursor = nil

          while !next_cursor.nil? && !next_cursor.empty? && next_cursor != old_cursor
            old_cursor = next_cursor
            params[:cursor] = next_cursor

            next_page = call_api(
              method,
              params
            )

            if next_page['error'] == 'ratelimited' && next_page['retry_after'] < 5
              sleep(next_page['retry_after'])
              old_cursor = nil
            else
              next_cursor = fetch_cursor(next_page)
              result[result_field] += next_page[result_field]
            end
          end
          result
        end

        def send_attachments(room_or_user, attachments)
          call_api(
            "chat.postMessage",
            as_user: true,
            channel: room_or_user.id,
            attachments: MultiJson.dump(attachments.map(&:to_hash)),
          )
        end

        def open_dialog(dialog, trigger_id)
          call_api(
            "dialog.open",
            dialog: MultiJson.dump(dialog),
            trigger_id: trigger_id,
          )
        end

        def send_messages(channel_id, messages)
          call_api(
            "chat.postMessage",
            **post_message_config,
            as_user: true,
            channel: channel_id,
            text: messages.join("\n"),
          )
        end

        def reply_in_thread(channel_id, messages, thread_ts)
          call_api(
            "chat.postMessage",
            as_user: true,
            channel: channel_id,
            text: messages.join("\n"),
            thread_ts: thread_ts
          )
        end

        def delete(channel, ts)
          call_api("chat.delete", channel: channel, ts: ts)
        end

        def update_attachments(channel, ts, attachments)
          call_api(
            "chat.update",
            channel: channel,
            ts: ts,
            attachments: MultiJson.dump(attachments.map(&:to_hash))
          )
        end

        def react_with_emoji(channel_id, emoji, ts)
          call_api(
            "reactions.add",
            **post_message_config,
            as_user: true,
            channel: channel_id,
            name: emoji,
            timestamp: ts
          )
        end

        def set_topic(channel, topic)
          call_api("channels.setTopic", channel: channel, topic: topic)
        end

        def rtm_start
          Lita.logger.debug("Starting `rtm_connect` method")
          response_data = call_api("rtm.connect")
          Lita.logger.debug("Started building TeamData")

          users_res_data = users_list
          conversations_res_data = conversations_list

          channels = conversations_res_data['channels'].select do |c|
            c['is_channel']
          end
          groups = conversations_res_data['channels'].select do |c|
            c['is_group']
          end
          ims = conversations_res_data['channels'].select do |c|
            c['is_im']
          end

          ims =
          team_data = TeamData.new(
            SlackIM.from_data_array(ims),
            SlackUser.from_data(response_data["self"]),
            SlackUser.from_data_array(users_res_data['members']),
            SlackChannel.from_data_array(channels) +
              SlackChannel.from_data_array(groups),
            response_data["url"],
          )
          Lita.logger.debug("Finished building TeamData")
          Lita.logger.debug("Finishing method `rtm_connect`")
          team_data
        end

        private

        attr_reader :stubs
        attr_reader :config
        attr_reader :post_message_config

        def call_api(method, post_data = {})
          Lita.logger.debug("Starting request to Slack API with rtm.start")
          response = connection.post(
            "https://slack.com/api/#{method}",
            { token: config.token }.merge(post_data)
          )
          Lita.logger.debug("Finished request to Slack API rtm.start")
          data = parse_response(response, method)
          Lita.logger.debug("Finished parsing rtm.start response")
          raise "Slack API call to #{method} returned an error: #{data["error"]}." if data["error"]

          data
        end

        def connection
          if stubs
            Faraday.new { |faraday| faraday.adapter(:test, stubs) }
          else
            options = {}
            unless config.proxy.nil?
              options = { proxy: config.proxy }
            end
            Faraday.new(options)
          end
        end

        def parse_response(response, method)
          unless response.status == 429 || response.success?
            raise "Slack API call to #{method} failed with status code #{response.status}: '#{response.body}'. Headers: #{response.headers}"
          end

          MultiJson.load(response.body)
        end

        def fetch_cursor(page)
          page.dig("response_metadata", "next_cursor")
        end
      end
    end
  end
end
