/**
 * Keep a copy button on every role=execute block.
 *
 * The Showroom theme adds that button, then 08-execute.js hides it and
 * makes the whole listing send the command to the terminal. Copy stays
 * available, and clicking it does not also run the command.
 */
;(function () {
  'use strict'

  function init () {
    var blocks = document.querySelectorAll('div.listingblock.execute')
    Array.prototype.forEach.call(blocks, equip)
  }

  function equip (block) {
    var code = block.querySelector('pre code')
    if (!code) return

    var button = block.querySelector('.copy-button')
    if (!button) {
      button = document.createElement('button')
      button.className = 'copy-button'
      button.type = 'button'
      code.parentNode.insertBefore(button, code)
    }

    button.type = 'button'
    button.style.display = ''
    button.setAttribute('title', 'Copy')
    if (!button.getAttribute('aria-label')) button.setAttribute('aria-label', 'Copy')

    var content = block.querySelector('.content')
    if (content) {
      Array.prototype.forEach.call(content.children, function (child) {
        if (child.textContent === '▶') child.classList.add('execute-run')
      })
    }

    button.addEventListener('click', function (event) {
      event.preventDefault()
      event.stopPropagation()
      copyText(code.textContent).then(function () {
        showCopied(button)
      }).catch(function () {
        button.setAttribute('aria-label', 'Copy failed')
      })
    })
  }

  function copyText (text) {
    if (navigator.clipboard && window.isSecureContext) {
      return navigator.clipboard.writeText(text)
    }
    return new Promise(function (resolve, reject) {
      var area = document.createElement('textarea')
      area.value = text
      area.setAttribute('readonly', '')
      area.style.position = 'fixed'
      area.style.left = '-9999px'
      document.body.appendChild(area)
      area.select()
      try {
        document.execCommand('copy') ? resolve() : reject(new Error('copy failed'))
      } catch (err) {
        reject(err)
      } finally {
        area.remove()
      }
    })
  }

  function showCopied (button) {
    button.setAttribute('class', 'copy-button tooltipped tooltipped-s tooltipped-no-delay')
    button.setAttribute('aria-label', 'Copied!')
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init)
  } else {
    init()
  }
})()
