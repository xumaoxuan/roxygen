
## If not specified in DESCRIPTION
markdown_global_default <- FALSE

## Hacky global switch - this uses the fact that blocks are parsed
## one after the another, and that we set markdown on/off before each
## block

markdown_env <- new.env(parent = emptyenv())
markdown_on <- function(value = NULL) {
  if (!is.null(value)) {
    assign("markdown-support", isTRUE(value), envir = markdown_env)
  }
  return(isTRUE(markdown_env$`markdown-support`))
}

restricted_markdown <- function(rest) {
  markdown(rest, markdown_tags_restricted)
}

full_markdown <- function(rest) {
  markdown(rest, markdown_tags)
}

#' @importFrom commonmark markdown_xml
#' @importFrom xml2 read_xml

markdown <- function(text, markdown_tags) {
  if (!markdown_on()) return(text)
  esc_text <- escape_rd_for_md(text)
  esc_text_linkrefs <- add_linkrefs_to_md(esc_text)
  md <- markdown_xml(esc_text_linkrefs, hardbreaks = TRUE)
  xml <- read_xml(md)
  rd_text <- str_trim(markdown_rparse(xml, markdown_tags))
  unescape_rd_for_md(rd_text, esc_text)
}

#' @importFrom xml2 xml_name xml_type xml_text xml_contents xml_attr
#'   xml_children
#' @importFrom methods is

markdown_rparse <- function(xml, markdown_tags) {

  ## We have a string, a list of things, or XML stuff

  ## Strings are simply returned
  if (is.character(xml)) return(paste(xml, collapse = ""))

  ## List is iterated over
  if (is(xml, "list")) {
    return(paste(vapply(xml, markdown_rparse, "", markdown_tags = markdown_tags),
                 collapse = ""))
  }

  ## Otherwise it is XML stuff, node set
  if (is(xml, "xml_nodeset")) {
    return(paste(vapply(xml, markdown_rparse, "", markdown_tags = markdown_tags),
                 collapse = ""))
  }

  ## text node, only keep if not entirely whitespace
  if (is(xml, "xml_node") && xml_type(xml) == "text") {
    return(ws_to_empty(xml_text(xml)))
  }

  ## generic node
  if (is(xml, "xml_node") && xml_type(xml) == "element") {
    return(markdown_rparse(markdown_tags[[ xml_name(xml) ]](xml), markdown_tags = markdown_tags))
  }

  warning("Unknown xml object")
}

markdown_tags <- list(

  unknown = function(xml) {
    ## Just ignore the tag, keep the contents
    xml_contents(xml)
  },

  document = function(xml) {
    ## Keep the contents only, tag does nothing
    xml_contents(xml)
  },

  block_quote = function(xml) {
    ## Cannot really format this in Rd, so we just leave it
    xml_contents(xml)
  },

  list = function(xml) {
    ## A list, either bulleted or numbered
    type <- xml_attr(xml, "type")
    if (type == "ordered") {
      list("\n\\enumerate{", xml_contents(xml), "\n}")
    } else {
      list("\n\\itemize{", xml_contents(xml), "\n}")
    }
  },

  item = function(xml) {
    ## A single item within a list. We remove the first paragraph
    ## tag, to avoid an empty line at the beginning of the first item.
    cnts <- xml_children(xml)
    if (length(cnts) == 0) {
      cnts <- ""
    } else if (xml_name(cnts[[1]]) == "paragraph") {
      cnts <- list(xml_contents(cnts[[1]]), cnts[-1])
    }
    list("\n\\item ", cnts)
  },

  code_block = function(xml) {
    ## Large block of code
    list("\\preformatted{", xml_contents(xml), "}")
  },

  html = function(xml) {
    ## Not sure what to do with this, we'll just leave it
    xml_contents(xml)
  },

  paragraph = function(xml) {
    ## Paragraph
    list("\n\n", xml_contents(xml))
  },

  header = function(xml) {
    ## Not sure what this is, ignore it for now.
    xml_contents(xml)
  },

  hrule = function(xml) {
    ## We cannot have horizontal rules, will just start a new
    ## paragraph instead.
    "\n\n"
  },

  text = function(xml) {
    ## Just ordinary text, leave it as it is.
    xml_text(xml)
  },

  softbreak = function(xml) {
    ## Inserted line break (?).
    "\n"
  },

  linebreak = function(xml) {
    ## Original line break (?).
    "\n"
  },

  code = function(xml) {
    list("\\code{", xml_contents(xml), "}")
  },

  html_inline = function(xml) {
    ## Will just ignore this for now.
    xml_contents(xml)
  },

  emph = function(xml) {
    ## Emphasized text.
    list("\\emph{", xml_contents(xml), "}")
  },

  strong = function(xml) {
    ## Bold text.
    list("\\strong{", xml_contents(xml), "}")
  },

  link = function(xml) {
    ## Hyperlink, this can also be a link to a function
    dest <- xml_attr(xml, "destination")
    contents <- xml_contents(xml)

    link <- parse_link(dest, contents)

    if (!is.null(link)) {
      link
    } else if (dest == "" || dest == xml_text(xml)) {
      list("\\url{", xml_text(xml), "}")
    } else {
      list("\\href{", dest, "}{", xml_text(xml), "}")
    }
  },

  image = function(xml) {
    dest <- xml_attr(xml, "destination")
    title <- xml_attr(xml, "title")
    paste0("\\figure{", dest, "}{", title, "}")
  }

)

markdown_tags_restricted <- markdown_tags

ws_to_empty <- function(x) {
  sub("^\\s*$", "", x)
}

#' Add link reference definitions for functions to a markdown text.
#'
#' We find the `[text][ref]` and the `[ref]` forms. There must be no
#' spaces between the closing and opening bracket in the `[text][ref]`
#' form.
#'
#' These are the link references we add:
#' ```
#'                                                        CODE
#' MARKDOWN          REFERENCE LINK             LINK TEXT | RD
#' --------          --------------             --------- - --
#' [fun()]           [fun()]: R:fun()           fun()     T \\link[=fun]{fun()}
#' [obj]             [obj]: R:obj               obj       F \\link{obj}
#' [pkg::fun()]       [pkg::fun()]: R:pkg::fun()  pkg::fun() T \\link[pkg:fun]{pkg::fun()}
#' [pkg::obj]         [pkg::obj]: R:pkg::obj      pkg::obj   F \\link[pkg:obj]{pkg::obj}
#' [text][fun()]     [fun()]: R:fun()           text      F \\link[=fun]{text}
#' [text][obj]       [obj]: R:obj               text      F \\link[=obj]{text}
#' [text][pkg::fun()] [pkg::fun()]: R:pkg::fun()  text      F \\link[pkg:fun]{text}
#' [text][pkg::obj]   [pkg::obj]: R:pkg::obj      text      F \\link[pkg:obj]{text}
#' ```
#'
#' These are explicitly tested in `test-rd-markdown-links.R`
#'
#' We add in a special `R:` marker to the URL. This way we don't
#' pick up other links, that were specified via `<url>` or
#' `[text](link)`. In the parsed XML tree these look the same as
#' our `[link]` and `[text][link]` links.
#'
#' In the link references, we need to URL encode the reference,
#' otherwise commonmark does not use it (see issue #518).
#'
#' @param text Input markdown text.
#' @return The input text and all dummy reference link definitions
#'   appended.
#'
#' @noRd
#' @importFrom utils URLencode URLdecode

add_linkrefs_to_md <- function(text) {

  refs <- str_match_all(
    text,
    regex("(?<=[^]]|^)\\[([^]]+)\\](?:\\[([^]]+)\\])?(?=[^\\[]|$)")
  )[[1]]

  if (length(refs) == 0) return(text)

  ## For the [fun] form the link text is the same as the destination.
  refs[, 3] <- ifelse(refs[,3] == "", refs[, 2], refs[,3])

  refs3encoded <- vapply(refs[,3], URLencode, "")
  ref_text <- paste0("[", refs[, 3], "]: ", "R:", refs3encoded)

  paste0(
    text,
    "\n\n",
    paste(ref_text, collapse = "\n"),
    "\n"
  )
}

#' Parse a MarkDown link, to see if we should create an Rd link
#'
#' See the table above.
#'
#' @param destination string constant, the "url" of the link
#' @param contents An XML node, containing the contents of the link.
#'
#' @noRd
#' @importFrom xml2 xml_name

parse_link <- function(destination, contents) {

  ## Not a [] or [][] type link, remove prefix if it is
  if (! grepl("^R:", destination)) return(NULL)
  destination <- sub("^R:", "", URLdecode(destination))

  ## if contents is a `code tag`, then we need to move this outside
  is_code <- FALSE
  if (length(contents) == 1 && xml_name(contents) == "code") {
    is_code <- TRUE
    contents <- xml_contents(contents)
    destination <- sub("`$", "", sub("^`", "", destination))
  }

  ## If the supplied link text is the same as the reference text,
  ## then we assume that the link text was automatically generated and
  ## it was not specified explicitly. In this case `()` links are
  ## turned to `\\code{}`.
  ## We also assume link text if we see a non-text XML tag in contents.
  has_link_text <- paste(xml_text(contents), collapse = "") != destination ||
    any(xml_name(contents) != "text")

  ## if (is_code) then we'll need \\code
  ## `pkg` is package or NA
  ## `fun` is fun() or obj (fun is with parens)
  ## `is_fun` is TRUE for fun(), FALSE for obj
  ## `obj` is fun or obj (fun is without parens)

  is_code <- is_code || (grepl("[(][)]$", destination) && ! has_link_text)
  pkg <- str_match(destination, "^(.*)::")[1,2]
  fun <- utils::tail(strsplit(destination, "::", fixed = TRUE)[[1]], 1)
  is_fun <- grepl("[(][)]$", fun)
  obj <- sub("[(][)]$", "", fun)

  ## To understand this, look at the RD column of the table above
  if (!has_link_text) {
    paste0(
      if (is_code) "\\code{",
      "\\link",
      if (is_fun || ! is.na(pkg)) "[",
      if (is_fun && is.na(pkg)) "=",
      if (! is.na(pkg)) paste0(pkg, ":"),
      if (is_fun || ! is.na(pkg)) paste0(obj, "]"),
      "{",
      if (!is.na(pkg)) paste0(pkg, "::"),
      fun,
      "}",
      if (is_code) "}"
    )

  } else {
    list(
      paste0(
        if (is_code) "\\code{",
        "\\link[",
        if (is.na(pkg)) "=" else paste0(pkg, ":"),
        obj,
        "]{"
      ),
      contents,
      "}"
    )
  }
}

## Check if a string contains a pattern exactly once. Overlapping
## patterns do not count.

contains_once <- function(x, pattern, ...) {
  length(strsplit(x = x, split = pattern, ...)[[1]]) == 2
}

#' @importFrom methods is

is_empty_xml <- function(x) {
  is(x, "xml_nodeset") && length(x) == 0
}

#' Dummy page to test roxygen's markdown formatting
#'
#' Links are very tricky, so I'll put in some links here:
#' Link to a function: [roxygenize()].
#' Link to an object: [roxygenize] (we just treat it like an object here.
#'
#' Link to another package, function: [devtools::document()].
#' Link to another package, non-function: [devtools::document].
#'
#' Link with link text:  [this great function][roxygenize()] or
#' [that great function][roxygenize].
#'
#' In another package: [and this one][devtools::document].
#'
#' @name markdown-test
#' @keywords internal
NULL
