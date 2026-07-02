require "base64"
require "open3"

module Properties
  class UploadTextExtractor
    MAX_BYTES = 8.megabytes
    TEXT_EXTENSIONS = %w[.txt .md .markdown .csv .json .html .htm .xml].freeze
    IMAGE_EXTENSIONS = %w[.jpg .jpeg .png .webp .gif].freeze

    class ExtractionError < StandardError; end

    def initialize(upload)
      @upload = upload
    end

    def call
      raise ExtractionError, "Subí un archivo para que Ayla pueda leerlo." if @upload.blank?
      raise ExtractionError, "El archivo es demasiado grande. Usá uno de hasta 8 MB." if @upload.size.to_i > MAX_BYTES

      {
        filename: filename,
        content_type: content_type,
        text: extracted_text,
        base64: base64_payload,
        kind: document_kind
      }
    end

    private

    def filename
      @upload.original_filename.to_s
    end

    def extension
      File.extname(filename).downcase
    end

    def content_type
      @content_type ||= @upload.content_type.presence || content_type_from_extension || "application/octet-stream"
    end

    def content_type_from_extension
      {
        ".txt" => "text/plain",
        ".md" => "text/markdown",
        ".markdown" => "text/markdown",
        ".csv" => "text/csv",
        ".json" => "application/json",
        ".html" => "text/html",
        ".htm" => "text/html",
        ".xml" => "application/xml",
        ".pdf" => "application/pdf",
        ".jpg" => "image/jpeg",
        ".jpeg" => "image/jpeg",
        ".png" => "image/png",
        ".webp" => "image/webp",
        ".gif" => "image/gif"
      }[extension]
    end

    def extracted_text
      if text_file?
        upload_bytes.force_encoding("UTF-8").scrub
      elsif pdf_file?
        extract_pdf_text
      else
        ""
      end
    end

    def base64_payload
      return unless image_file? || pdf_file?

      Base64.strict_encode64(upload_bytes)
    end

    def document_kind
      return "image" if image_file?
      return "pdf" if pdf_file?
      return "text" if text_file?

      "file"
    end

    def text_file?
      content_type.start_with?("text/") ||
        content_type.in?(%w[application/json application/xml]) ||
        TEXT_EXTENSIONS.include?(extension)
    end

    def image_file?
      content_type.start_with?("image/") || IMAGE_EXTENSIONS.include?(extension)
    end

    def pdf_file?
      content_type == "application/pdf" || extension == ".pdf"
    end

    def upload_bytes
      @upload_bytes ||= begin
        @upload.tempfile.rewind
        @upload.tempfile.read
      end
    end

    def extract_pdf_text
      output, _error, status = Open3.capture3("pdftotext", "-layout", @upload.tempfile.path, "-")
      return output.to_s.force_encoding("UTF-8").scrub if status.success?

      ""
    rescue Errno::ENOENT
      ""
    end
  end
end
