# encoding: UTF-8
require 'spreadsheet'
module RailsAdminExportToXls
  class XLSConverter
    UTF8_ENCODINGS = [nil, '', 'utf8', 'utf-8', 'unicode', 'UTF8', 'UTF-8', 'UNICODE', 'utf8mb4']
    TARGET_ENCODINGS = %w(UTF-8 UTF-16LE UTF-16BE UTF-32LE UTF-32BE UTF-7 ISO-8859-1 ISO-8859-15 IBM850 MacRoman Windows-1252 ISO-8859-3 IBM852 ISO-8859-2 Windows-1250 IBM855 ISO-8859-5 KOI8-R MacCyrillic Windows-1251 IBM866 GB2312 GBK GB18030 Big5 Big5-HKSCS EUC-TW EUC-JP ISO-2022-JP Shift_JIS EUC-KR)
    def initialize(objects = [], schema = {})
      @fields = []
      @associations = []

      return self if (@objects = objects).blank?

      @model = objects.dup.first.class
      @abstract_model = RailsAdmin::AbstractModel.new(@model)
      @model_config = @abstract_model.config
      @methods = [(schema[:only] || []) + (schema[:methods] || [])].flatten.compact
      @fields = @methods.collect { |m| export_fields_for(m).first }
      @empty = ::I18n.t('admin.export.empty_value_for_associated_objects')
      schema_include = schema.delete(:include) || {}

      @associations = schema_include.each_with_object({}) do |(key, values), hash|
        association = association_for(key)
        model_config = association.associated_model_config
        abstract_model = model_config.abstract_model
        methods = [(values[:only] || []) + (values[:methods] || [])].flatten.compact

        hash[key] = {
          association: association,
          model: abstract_model.model,
          abstract_model: abstract_model,
          model_config: model_config,
          fields: methods.collect { |m| export_fields_for(m, model_config).first },
        }
        hash
      end
    end

    def to_xls(options = {})
      # encoding shenanigans first
      # @encoding_from = Encoding.find(UTF8_ENCODINGS.include?(@abstract_model.encoding) ? 'UTF-8' : @abstract_model.encoding)
      # @encoding_to = Encoding.find(options[:encoding_to].presence || @encoding_from)

      # xls_string = generate_xls_string(options)

      # if @encoding_to != @encoding_from
      #   xls_string = xls_string.encode(@encoding_to, @encoding_from, invalid: :replace, undef: :replace, replace: '?')
      # end
      # Add a BOM for utf8 encodings, helps with utf8 auto-detect for some versions of Excel.
      # Don't add if utf8 but user don't want to touch input encoding:
      # If user chooses utf8, they will open it in utf8 and BOM will disappear at reading.
      # But that way "English" users who don't bother and chooses to let utf8 by default won't get BOM added
      # and will not see it if Excel opens the file with a different encoding.
      # if options[:encoding_to].present? && @encoding_to == Encoding::UTF_8
      #   xls_string = "\xEF\xBB\xBF#{xls_string}"
      # end
      book = ::Spreadsheet::Workbook.new

      # Font
      book_format = Spreadsheet::Format.new(
        font: Spreadsheet::Font.new('Arial'),
        size: 10,
        vertical_align: :middle,
        horizontal_align: :left,
      )
      book.add_format(book_format)

      sheet = book.create_worksheet
      sheet.default_format = book_format

      # Header
      header_format = Spreadsheet::Format.new(
        size: 10,
        weight: :bold,
        vertical_align: :middle,
        horizontal_align: :left,
        # pattern_bg_color: :grey,
        # pattern: 0xfc000000
      )
      sheet.row(0).default_format = header_format
      sheet.row(0).height = 20
      sheet.row(0).concat generate_xls_header

      # Content
      row = 1
      method = @objects.respond_to?(:find_each) ? :find_each : :each
      @objects.send(method) do |object|
        sheet.row(row).concat generate_xls_row(object)
        sheet.row(row).height = 20
        row = row + 1
      end

      # Column width formatting
      (0...sheet.column_count).each do |col_idx| 
        column = sheet.column(col_idx) 
        column.width = column.each_with_index.map do |cell, row|
          chars = if cell.present? 
            arr = cell.to_s.strip.split("\n")
            count = arr.map do |comp|
              comp.split('').count
            end.max
            count + 3 # buffer
          else
            1
          end

          ratio = sheet.row(row).format(col_idx).font.size / 10
          (chars * ratio).round
        end.max 
      end
      # Column height formatting
      (0...sheet.row_count).each do |row_idx|
        row = sheet.row(row_idx)
        row.height = row.each_with_index.map do |cell, column|
          multiplier = if cell.present?
            cell.to_s.lines.count
          else
            1
          end
          calculated_height = (row.format(column).font.size + 4) * multiplier
          [calculated_height, 20].max
        end.max
      end

      buffer = StringIO.new
      book.write(buffer)

      [!options[:skip_header], @encoding_to.to_s, buffer.string]
    end

  private

    def association_for(key)
      export_fields_for(key).detect(&:association?)
    end

    def export_fields_for(method, model_config = @model_config)
      names = model_config.export.fields.collect { |f| f.name }
      model_config.export.fields.select { |f| f.name.to_s == method.to_s }
    end

    # def generate_xls_string(options)
    #   generator_options = (options[:generator] || {}).symbolize_keys.delete_if { |_, value| value.blank? }
    #   CSV.generate(generator_options) do |xls|
    #     xls << generate_xls_header unless options[:skip_header]
    #
    #     method = @objects.respond_to?(:find_each) ? :find_each : :each
    #     @objects.send(method) do |object|
    #       xls << generate_xls_row(object)
    #     end
    #   end
    # end

    def generate_xls_header
      @fields.collect do |field|
        ::I18n.t('admin.export.csv.header_for_root_methods', name: field.label, model: @abstract_model.pretty_name)
      end +
        @associations.flat_map do |_association_name, option_hash|
          option_hash[:fields].collect do |field|
            ::I18n.t('admin.export.csv.header_for_association_methods', name: field.label, association: option_hash[:association].label)
          end
        end
    end

    def generate_xls_row(object)
      @fields.collect do |field|
        field.with(object: object).export_value
      end +
        @associations.flat_map do |association_name, option_hash|
          associated_objects = [object.send(association_name)].flatten.compact
          option_hash[:fields].collect do |field|
            associated_objects.collect { |ao| field.with(object: ao).export_value.presence || @empty }.join(',')
          end
        end
    end
  end
end
