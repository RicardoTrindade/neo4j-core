module Neo4j
  module Core
    module Index

      # This class is delegated from the Neo4j::Core::Index::ClassMethod
      # @see Neo4j::Core::Index::ClassMethods
      class Indexer
        # @return [Neo4j::Core::Index::IndexConfig]
        attr_reader :config

        def initialize(config)
          @config = config
          @indexes = {} # key = type, value = java neo4j index
                        # to enable subclass indexing to work properly, store a list of parent indexers and
                        # whenever an operation is performed on this one, perform it on all
        end


        def to_s
          "Indexer @#{object_id} index on: [#{@config.fields.map{|f| @config.numeric?(f)? "#{f} (numeric)" : f}.join(', ')}]"
        end

        # Add an index on a field so that it will be automatically updated by neo4j transactional events.
        #
        # The index method takes an optional configuration hash which allows you to:
        #
        # @example Add an index on an a property
        #
        #   class Person
        #     include Neo4j::NodeMixin
        #     index :name
        #   end
        #
        # When the property name is changed/deleted or the node created it will keep the lucene index in sync.
        # You can then perform a lucene query like this: Person.find('name: andreas')
        #
        # @example Add index on other nodes.
        #
        #   class Person
        #     include Neo4j::NodeMixin
        #     has_n(:friends).to(Contact)
        #     has_n(:known_by).from(:friends)
        #     index :user_id, :via => :known_by
        #   end
        #
        # Notice that you *must* specify an incoming relationship with the via key, as shown above.
        # In the example above an index <tt>user_id</tt> will be added to all Person nodes which has a <tt>friends</tt> relationship
        # that person with that user_id. This allows you to do lucene queries on your friends properties.
        #
        # @example Set the type value to index
        #
        #   class Person
        #     include Neo4j::NodeMixin
        #     property :height, :weight, :type => Float
        #     index :height, :weight
        #   end
        #
        # By default all values will be indexed as Strings.
        # If you want for example to do a numerical range query you must tell Neo4j.rb to index it as a numeric value.
        # You do that with the key <tt>type</tt> on the property.
        #
        # Supported values for <tt>:type</tt> is <tt>String</tt>, <tt>Float</tt>, <tt>Date</tt>, <tt>DateTime</tt> and <tt>Fixnum</tt>
        #
        # === For more information
        #
        # @see Neo4j::Core::Index::LuceneQuery
        # @see #find
        #
        def index(*args)
          @config.index(args)
        end

        # @return [true,false] if there is an index on the given field.
        def index?(field)
          @config.index?(field)
        end

        # @return [true,false] if the
        def trigger_on?(props)
          @config.trigger_on?(props)
        end

        # @return [Symbol] the type of index for the given field (e.g. :exact or :fulltext)
        def index_type(field)
          @config.index_type(field)
        end

        # @return [true,false]  if there is an index of the given type defined.
        def has_index_type?(type)
          @config.has_index_type?(type)
        end

        # Adds an index on the given entity
        # This is normally not needed since you can instead declare an index which will automatically keep
        # the lucene index in sync.
        # @see #index
        def add_index(entity, field, value)
          return false unless index?(field)
          conv_value = indexed_value_for(field, value)
          index = index_for_field(field.to_s)
          index.add(entity, field, conv_value)
        end


        # Removes an index on the given entity
        # This is normally not needed since you can instead declare an index which will automatically keep
        # the lucene index in sync.
        # @see #index
        def rm_index(entity, field, value)
          return false unless index?(field)
          index_for_field(field).remove(entity, field, value)
        end

        # Performs a Lucene Query.
        #
        # In order to use this you have to declare an index on the fields first, see #index.
        # Notice that you should close the lucene query after the query has been executed.
        # You can do that either by provide an block or calling the Neo4j::Core::Index::LuceneQuery#close
        # method. When performing queries from Ruby on Rails you do not need this since it will be automatically closed
        # (by Rack).
        #
        # @example with a block
        #
        #   Person.find('name: kalle') {|query| puts "#{[*query].join(', )"}
        #
        # @example
        #
        #   query = Person.find('name: kalle')
        #   puts "First item #{query.first}"
        #   query.close
        #
        # @return [Neo4j::Core::Index::LuceneQuery] a query object
        def find(query, params = {})
          index = index_for_type(params[:type] || :exact)
          if query.is_a?(Hash) && (query.include?(:conditions) || query.include?(:sort))
            params.merge! query.reject { |k, _| k == :conditions }
            query.delete(:sort)
            query = query.delete(:conditions) if query.include?(:conditions)
          end
          query = (params[:wrapped].nil? || params[:wrapped]) ? LuceneQuery.new(index, @config, query, params) : index.query(query)

          if block_given?
            begin
              ret = yield query
            ensure
              query.close
            end
            ret
          else
            query
          end
        end

        # Delete all index configuration. No more automatic indexing will be performed
        def rm_index_config
          @config.rm_index_config
        end

        # delete the index, if no type is provided clear all types of indexes
        def rm_index_type(type=nil)
          if type
            key = @config.index_name_for_type(type)
            @indexes[key] && @indexes[key].delete
            @indexes[key] = nil
          else
            @indexes.each_value { |index| index.delete }
            @indexes.clear
          end
        end

        # Called when the neo4j shutdown in order to release references to indexes
        def on_neo4j_shutdown
          @indexes.clear
        end

        # Called from the event handler when a new node or relationships is about to be committed.
        def update_index_on(node, field, old_val, new_val)
          if index?(field)
            rm_index(node, field, old_val) if old_val
            add_index(node, field, new_val) if new_val
          end
        end

        # Called from the event handler when deleting a property
        def remove_index_on(node, old_props)
          @config.fields.each { |field| rm_index(node, field, old_props[field]) if old_props[field] }
        end

        # Creates a wrapped ValueContext for the given value. Checks if it's numeric value in the configuration.
        # @return [Java::OrgNeo4jIndexLucene::ValueContext] a wrapped neo4j lucene value context
        def indexed_value_for(field, value)
          if @config.numeric?(field)
            Java::OrgNeo4jIndexLucene::ValueContext.new(value).indexNumeric
          else
            Java::OrgNeo4jIndexLucene::ValueContext.new(value)
          end
        end

        # @return [Java::OrgNeo4jGraphdb::Index] for the given field
        def index_for_field(field)
          type = @config.index_type(field)
          index_name = index_name_for_type(type)
          @indexes[index_name] ||= create_index_with(type, index_name)
        end

        # @return [Java::OrgNeo4jGraphdb::Index] for the given index type
        def index_for_type(type)
          index_name = index_name_for_type(type)
          @indexes[index_name] ||= create_index_with(type, index_name)
        end

        # @return [String] the name of the index which are stored on the filesystem
        def index_name_for_type(type)
          @config.index_name_for_type(type)
        end

        # @return [Hash] the lucene config for the given index type
        def lucene_config(type)
          conf = Neo4j::Config[:lucene][type.to_s]
          raise "unknown lucene type #{type}" unless conf
          conf
        end

        # Creates a new lucene index using the lucene configuration for the given index_name
        #
        # @param [:node, :relationship] type relationship or node index
        # @param [String] index_name the (file) name of the index
        # @return [Java::OrgNeo4jGraphdb::Index] for the given index type
        def create_index_with(type, index_name)
          db = Neo4j.started_db
          index_config = lucene_config(type)
          if config.entity_type == :node
            db.lucene.for_nodes(index_name, index_config)
          else
            db.lucene.for_relationships(index_name, index_config)
          end
        end


      end
    end
  end
end