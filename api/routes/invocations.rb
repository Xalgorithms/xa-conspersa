module Tatev
  module API
    module Routes
      class Invocations < Grape::API
        version 'v1'

        helpers do
          def logger
            Invocations.logger
          end
        end
        
        resource :invocations do
          params do
            requires :client, type: Hash do
              requires :id, type: String
            end
            requires :contexts, type: Array do
              requires :content, type: Hash
              requires :rules, type: Array do
                requires :id, type: String
                requires :version, type: String
              end
            end
          end
          
          post do
            args = declared(params)

            logger.info("# storing invocation and contexts")
            im = Invocation.create(client_id: args.client.id, public_id: UUID.generate)

            im.contexts = args.contexts.map do |context|
              cm = Context.create(public_id: UUID.generate, status: 'started')
              cm.rules = context.rules.map do |rule|
                Rule.first(source_id: rule.id, version: rule.version)
              end.reject(&:nil?)
              cm.current_rule = cm.rules.first
              cm.save
              cm
            end
            im.save

            # store in repo
            repo = Repository.new(Padrino.root('repos', im.client_id))
            im.contexts.each_with_index do |cm, i|
              content = args.contexts[i].content.to_hash
              repo.add(im.public_id, cm.public_id, content)
            end
            
            Tatev::Queue.live do |q|
              im.contexts.each do |cm|
                q.publish(context_id: cm.public_id)
              end
            end
            
            { invocation: { id: im.public_id }, contexts: im.contexts.map { |cm| { id: cm.public_id, status: cm.status.to_sym } } }
          end
        end

        # incoming from RP
        resource :contexts do
          route_param :public_id do
            params do
              requires :public_id, type: String
              requires :content, type: Hash
            end

            post do
              args = declared(params)
              logger.info("> new content")
              Context.with(public_id: args.public_id) do |cm|
                repo = Repository.new(Padrino.root('repos', cm.invocation.client_id))
                repo.update(cm.invocation.public_id, cm.public_id, args.content.to_hash)
                Tatev::Queue.live do |q|
                  q.publish(context_id: cm.public_id)
                end
              end

              { status: :ok }
            end
          end
        end
        
        resource :invocations do
          route_param :id do
            get do
            end
          end
        end

        # temporary... this is not loading in another module... Also it really will get moved to the RP
        resource :rules do
          route_param :id do
            route_param :rule_version do
              resource :invocations do
                params do
                  requires :id, type: String
                  requires :rule_version, type: String
                  requires :content, type: Hash
                  requires :context_id, type: String
                end

                post do
                  args = declared(params)
                  logger.info("> #{args.id}/#{args.rule_version}")
                  logger.info(">> #{args.content.inspect}")

                  # queue me
                  rules = Tatev::Rules.new
                  new_content = rules.execute(args.id, args.rule_version, args.content.to_hash)

                  logger.info("new_content: #{new_content.inspect}")
                  
                  api = Tatev::RegistryAPI.new(ENV.fetch('TATEV_REGISTRY_URL', 'http://localhost:8000'))
                  api.update(args.context_id, new_content)
                  
                  { status: :ok }
                end
              end
            end
          end
        end
      end
    end
  end
end
