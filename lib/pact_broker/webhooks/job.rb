require 'sucker_punch'
require 'pact_broker/webhooks/service'
require 'pact_broker/logging'

module PactBroker
  module Webhooks
    class Job

      include SuckerPunch::Job
      include PactBroker::Logging

      def perform data
        @data = data
        @triggered_webhook = data[:triggered_webhook]
        @error_count = data[:error_count] || 0
        begin
          webhook_execution_result = PactBroker::Webhooks::Service.execute_triggered_webhook_now triggered_webhook, execution_options
          if webhook_execution_result.success?
            handle_success
          else
            handle_failure
          end
        rescue StandardError => e
          handle_error e
        end
      end

      private

      attr_reader :triggered_webhook, :error_count

      def execution_options
        {
          success_log_message: "Successfully executed webhook",
          failure_log_message: failure_log_message
        }
      end

      def failure_log_message
        if reschedule_job?
          "Retrying webhook in #{backoff_time} seconds"
        else
          "Webhook execution failed after #{retry_schedule.size + 1} attempts"
        end
      end

      def handle_error e
        log_error e, "Error executing triggered webhook with ID #{triggered_webhook ? triggered_webhook.id : nil}"
        handle_failure
      end

      def handle_success
        update_triggered_webhook_status TriggeredWebhook::STATUS_SUCCESS
      end

      def handle_failure
        if reschedule_job?
          reschedule_job
          update_triggered_webhook_status TriggeredWebhook::STATUS_RETRYING
        else
          logger.error "Failed to execute webhook #{triggered_webhook.webhook_uuid} after #{retry_schedule.size + 1} attempts."
          update_triggered_webhook_status TriggeredWebhook::STATUS_FAILURE
        end
      end

      def reschedule_job?
        error_count < retry_schedule.size
      end

      def reschedule_job
        logger.debug "Re-enqeuing job for webhook #{triggered_webhook.webhook_uuid} to run in #{backoff_time} seconds"
        Job.perform_in(backoff_time, @data.merge(error_count: error_count+1))
      end

      def update_triggered_webhook_status status
        PactBroker::Webhooks::Service.update_triggered_webhook_status triggered_webhook, status
      end

      def backoff_time
        retry_schedule[error_count]
      end

      def retry_schedule
        PactBroker.configuration.webhook_retry_schedule
      end
    end
  end
end
